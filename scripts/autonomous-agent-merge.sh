#!/usr/bin/env bash
# autonomous-agent-merge.sh
#
# Polls Linear for "Merge" tickets, then merges them one-by-one using
# /ticket-merge. Shows live streaming output with real-time phase banners
# and a structured per-phase summary at the end of each ticket.
#
# Usage:
#   ./scripts/autonomous-agent-merge.sh [--poll-interval <seconds>] [--once] [--reset]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load stage config
# shellcheck source=scripts/stages/merge.env
source "$SCRIPT_DIR/stages/merge.env"

# Set derived paths that depend on SCRIPT_DIR
LOG_DIR="$SCRIPT_DIR/autonomous-merge-logs"
PROCESSED_FILE="/tmp/autonomous-merge-processed.txt"

# Load shared library
# shellcheck source=scripts/lib/agent-core.sh
source "$SCRIPT_DIR/lib/agent-core.sh"

# ── Stage-specific: stream processor with merge-result detection ──────────────

write_stage_processor() {
    PROCESSOR="/tmp/merge-processor-$$.py"
    cat > "$PROCESSOR" << 'PYEOF'
#!/usr/bin/env python3
"""
Reads Claude stream-json from stdin.
Prints formatted output with real-time Phase transition banners and surfaces
the merge result from /ticket-merge output.
Usage: python3 <script> <ticket_id>
"""
import sys, json, re, os

ticket_id = sys.argv[1] if len(sys.argv) > 1 else "TICKET-?"
heartbeat_file = sys.argv[2] if len(sys.argv) > 2 else None

R  = '\033[0m'
BL = '\033[0;34m'   # blue
MG = '\033[0;35m'   # magenta
GN = '\033[0;32m'   # green
RD = '\033[0;31m'   # red
BD = '\033[1m'      # bold
DM = '\033[2m'      # dim
YL = '\033[1;33m'   # yellow

PHASE_RE  = re.compile(r'##\s+(Phase\s+\d+[ab]?\s*[—–-]+\s*[^\n]+)', re.IGNORECASE)
DONE_RE   = re.compile(r'/ticket-merge.*complete|✅.*complete|merged.*→.*develop|Repository is clean', re.IGNORECASE)
ERROR_RE  = re.compile(r'ERROR:|Cannot auto-merge|Merge failed|conflicts found', re.IGNORECASE)

current_phase = ""
result_seen   = False

def emit(line):
    print(line, flush=True)

for raw in sys.stdin:
    raw = raw.rstrip()
    if not raw:
        continue
    try:
        event = json.loads(raw)
    except Exception:
        continue

    if heartbeat_file:
        try: os.utime(heartbeat_file, None)
        except OSError: pass

    etype = event.get('type', '')

    if etype == 'assistant':
        for block in (event.get('message') or {}).get('content', []):
            btype = block.get('type', '')

            if btype == 'text':
                text = block.get('text', '')

                # Phase transition banner
                m = PHASE_RE.search(text)
                if m:
                    new_phase = m.group(1).strip()
                    new_phase = re.sub(r'\s*[—–-]+\s*', ' — ', new_phase, count=1)
                    if new_phase != current_phase:
                        emit(f'\n{MG}{"━"*3} ▶ {BD}{new_phase}{R}{MG} {"━"*28}{R}')
                        current_phase = new_phase

                # Merge result highlight
                if not result_seen:
                    if DONE_RE.search(text):
                        result_seen = True
                        emit(f'\n{GN}{"█"*62}{R}')
                        emit(f'{GN}{BD}  ✅  MERGED — branch cleaned up, Linear → Done{R}')
                        emit(f'{GN}{"█"*62}{R}\n')
                    elif ERROR_RE.search(text):
                        result_seen = True
                        emit(f'\n{RD}{"█"*62}{R}')
                        emit(f'{RD}{BD}  ❌  MERGE FAILED — manual intervention required{R}')
                        emit(f'{RD}{"█"*62}{R}\n')

                for line in text.splitlines():
                    emit(f'{BL}[{ticket_id}]{R} {line}')

            elif btype == 'tool_use':
                name = block.get('name', '')
                inp  = block.get('input', {})
                hint = ''
                if name in ('Bash', 'bash'):
                    cmd = (inp.get('command') or '')[:80]
                    hint = f'  {DM}{cmd}{R}'
                elif name in ('Read', 'Edit', 'Write', 'Glob', 'Grep'):
                    path = inp.get('file_path') or inp.get('path') or inp.get('pattern') or ''
                    hint = f'  {DM}{path}{R}'
                emit(f'{DM}[{ticket_id}] 🔧  {name}{hint}{R}')

    elif etype == 'tool_use':
        name = event.get('name', '')
        if name:
            emit(f'{DM}[{ticket_id}] 🔧  {name}{R}')

    elif etype == 'result':
        if event.get('is_error'):
            err = str(event.get('result', 'unknown'))[:300]
            emit(f'{RD}[{ticket_id}] ❌  Error: {err}{R}')

    elif etype == 'system':
        if event.get('subtype') == 'init':
            emit(f'{DM}[{ticket_id}] Session started{R}')
PYEOF
}

# ── Stage-specific: cache helpers ─────────────────────────────────────────────

unmark_processed() { sed -i.bak "/^${1}$/d" "$PROCESSED_FILE" 2>/dev/null && rm -f "${PROCESSED_FILE}.bak" 2>/dev/null; true; }

# Remove cached tickets that are no longer in Merge status.
prune_cache() {
    local cached
    cached=$(grep -oE "${LINEAR_TEAM_KEY}-[0-9]+" "$PROCESSED_FILE" 2>/dev/null || true)
    [[ -z "$cached" ]] && return

    while IFS= read -r tid; do
        if ! ticket_still_merging "$tid"; then
            unmark_processed "$tid"
            log INFO "  Evicted from cache (no longer Merge): $tid"
        fi
    done <<< "$cached"
}

# ── Stage-specific: merging-state check ──────────────────────────────────────
# Unlike stage_still_actionable, this returns 0 on API failure (safe default).

ticket_still_merging() {
    local ticket_id="$1"
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        return 0
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${team_key}\\\"}},number:{eq:${issue_num}}}) { nodes { state { name } } } }\"}" \
        https://api.linear.app/graphql 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        log WARN "  Linear status check failed for $ticket_id — assuming still Merge"
        return 0
    fi

    local state_name
    state_name=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
nodes = data.get('data', {}).get('issues', {}).get('nodes', [])
print(nodes[0]['state']['name'] if nodes else '')
" <<< "$response" 2>/dev/null)

    [[ "$state_name" == "Merge" ]]
}

# ── Stage-specific: pre-poll hook (prune cache) ───────────────────────────────

stage_pre_poll_hook() {
    prune_cache
}

# ── Stage-specific: outcome detection + git cleanup ───────────────────────────

stage_pre_revert_cleanup() {
    local ticket_id="$1"
    if [[ -d "${REPO_ROOT}/.git" ]]; then
        git -C "$REPO_ROOT" rebase --abort 2>/dev/null || true
        git -C "$REPO_ROOT" merge --abort 2>/dev/null || true
        git -C "$REPO_ROOT" cherry-pick --abort 2>/dev/null || true
    fi
}

stage_print_completion_log() {
    local ticket_id="$1"
    local exit_code="$2"
    local ended_at; ended_at=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ $exit_code -eq 0 ]]; then
        log OK "✓ Merge session ended cleanly for $ticket_id  ($ended_at)"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi
}

stage_postprocess_ticket() {
    local ticket_id="$1"
    local log_file="$2"
    local exit_code="$3"

    # Determine outcome from log
    local outcome="unknown"
    if python3 - < "$log_file" 2>/dev/null << 'PYEOF' | grep -qiE "ticket-merge.*complete|repository is clean|merged.*→"; then
import sys, json
for raw in sys.stdin:
    try:
        e = json.loads(raw.rstrip())
    except:
        continue
    if e.get('type') == 'assistant':
        for b in (e.get('message') or {}).get('content', []):
            if b.get('type') == 'text':
                print(b['text'])
PYEOF
        outcome="MERGED"
    elif python3 - < "$log_file" 2>/dev/null << 'PYEOF' | grep -qiE "ERROR:|cannot auto-merge|merge failed|conflicts found"; then
import sys, json
for raw in sys.stdin:
    try:
        e = json.loads(raw.rstrip())
    except:
        continue
    if e.get('type') == 'assistant':
        for b in (e.get('message') or {}).get('content', []):
            if b.get('type') == 'text':
                print(b['text'])
PYEOF
        outcome="FAILED"
    fi

    case "$outcome" in
        MERGED)
            echo ""
            echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════╗${RESET}"
            echo -e "${GREEN}${BOLD}  ║  ✅  MERGED — branch cleaned up, Linear → Done      ║${RESET}"
            echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════╝${RESET}"
            echo ""
            log DONE "Merged and closed: $ticket_id"
            ;;
        FAILED)
            echo ""
            echo -e "${RED}${BOLD}  ╔══════════════════════════════════════════════════════╗${RESET}"
            echo -e "${RED}${BOLD}  ║  ❌  MERGE FAILED — manual intervention required     ║${RESET}"
            echo -e "${RED}${BOLD}  ║  See log: $log_file  ║${RESET}"
            echo -e "${RED}${BOLD}  ╚══════════════════════════════════════════════════════╝${RESET}"
            echo ""
            log FAIL "Merge failed for $ticket_id — check log: $log_file"
            ;;
        *)
            log WARN "Outcome unclear for $ticket_id — check log: $log_file"
            ;;
    esac
}

# ── Stage-specific: post-exit revert (Merge → Human Review) ─────────
# Merge is dangerous: if it exits with the ticket still in 'Merge'
# (i.e. the merge did not complete), kick it back to 'Human Review' rather than
# auto-retrying a partial merge.

stage_post_exit_revert() {
    local ticket_id="$1"
    local revert_state="$2"
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local final_state
        final_state=$(get_ticket_state "$ticket_id") || final_state=""
        if [[ "$final_state" == "Merge" ]]; then
            log WARN "$ticket_id still '$final_state' after exit — reverting to 'Human Review'"
            revert_ticket_status "$ticket_id" "Human Review"
        fi
    fi
}

# ── Stage-specific: still-actionable uses ticket_still_merging ───────────────

stage_still_actionable() {
    ticket_still_merging "$1"
}

# ── Stage-specific: summary prompt ────────────────────────────────────────────

stage_build_summary_prompt() {
    local ticket_id="$1"
    cat << PROMPT_EOF
Below is the raw output from merging Linear ticket ${ticket_id} via /ticket-merge.

Write a concise per-phase summary of what actually happened. Use ONLY phases that ran. Format each line as:

**Phase N — [Name]:** <1-2 sentence conclusion>

Phases to cover if they ran:
- Phase 0 — Resolve Branch: branch name found (feat/ or fix/)
- Phase 0.5 — Resolve Merge Target: target branch (develop or parent feature branch)
- Phase 1 — Safety Checks: fetch/pull status, conflict check result
- Phase 2 — Merge: merge commit created (--no-ff), any issues
- Phase 3 — Push: push to origin verified or failed
- Phase 4 — Linear Update: ticket moved to Done, comment posted
- Phase 5 — Worktree Cleanup: worktree removed via wtp or git
- Phase 6 — Branch Deletion: local + remote branch deleted
- Phase 7 — Final Report: overall outcome

End with a one-line outcome: MERGED ✅ or FAILED ❌ with the key reason.
Be factual. No filler.
PROMPT_EOF
}

# ── Stage-specific: colorize merge summary (MERGED=green, FAILED=red, else cyan)

_colorize_summary_lines() {
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "MERGED|✅"; then
            echo -e "${GREEN}  ${line}${RESET}"
        elif echo "$line" | grep -qiE "FAILED|❌"; then
            echo -e "${RED}  ${line}${RESET}"
        else
            echo -e "${CYAN}  ${line}${RESET}"
        fi
    done
}

run_main_loop "$@"
