#!/usr/bin/env bash
# autonomous-agent-code-review.sh
#
# Polls Linear for "Code Review" tickets, then reviews them one-by-one using
# /ticket-code-review. Shows live streaming output with real-time phase banners
# and a structured per-phase summary at the end of each ticket.
#
# After /ticket-code-review completes:
#   PASS  → ticket moves to "Human Review"; script notifies you to verify
#   FAIL  → ticket moves to "Changes Required"; full findings logged
#
# Usage:
#   ./scripts/autonomous-agent-code-review.sh [--poll-interval <seconds>] [--once] [--reset]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load stage config
# shellcheck source=scripts/stages/code-review.env
source "$SCRIPT_DIR/stages/code-review.env"

# Set derived paths that depend on SCRIPT_DIR
LOG_DIR="$SCRIPT_DIR/autonomous-code-review-logs"
PROCESSED_FILE="/tmp/autonomous-code-review-processed.txt"

# Load shared library
# shellcheck source=scripts/lib/agent-core.sh
source "$SCRIPT_DIR/lib/agent-core.sh"

# ── Stage-specific: stream processor with PASS/FAIL verdict detection ─────────

write_stage_processor() {
    PROCESSOR="/tmp/code-review-processor-$$.py"
    cat > "$PROCESSOR" << 'PYEOF'
#!/usr/bin/env python3
"""
Reads Claude stream-json from stdin.
Prints formatted output with real-time Phase transition banners and surfaces
the PASS/FAIL verdict from /ticket-code-review output.
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
CY = '\033[0;36m'   # cyan

PHASE_RE  = re.compile(r'##\s+(Phase\s+\d+[ab]?\s*[—–-]+\s*[^\n]+)', re.IGNORECASE)
PASS_RE   = re.compile(r'\bPASS\b.*✅|✅.*\bPASS\b|## Review:.*PASS', re.IGNORECASE)
FAIL_RE   = re.compile(r'\bFAIL\b.*❌|❌.*\bFAIL\b|## Review:.*FAIL|Changes Required', re.IGNORECASE)
VERDICT_RE = re.compile(r'### Verdict', re.IGNORECASE)

current_phase = ""
verdict_seen  = False

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

                # Verdict highlight (PASS or FAIL)
                if VERDICT_RE.search(text) and not verdict_seen:
                    verdict_seen = True
                    if PASS_RE.search(text):
                        emit(f'\n{GN}{"█"*62}{R}')
                        emit(f'{GN}{BD}  ✅  VERDICT: PASS — moving to Human Review{R}')
                        emit(f'{GN}{"█"*62}{R}\n')
                    elif FAIL_RE.search(text):
                        emit(f'\n{RD}{"█"*62}{R}')
                        emit(f'{RD}{BD}  ❌  VERDICT: FAIL — moving to Changes Required{R}')
                        emit(f'{RD}{"█"*62}{R}\n')

                # Inline PASS/FAIL detection outside Verdict section
                if not verdict_seen:
                    if PASS_RE.search(text):
                        emit(f'{GN}{BD}[{ticket_id}] ✅  PASS detected{R}')
                        verdict_seen = True
                    elif FAIL_RE.search(text):
                        emit(f'{RD}{BD}[{ticket_id}] ❌  FAIL detected{R}')
                        verdict_seen = True

                for line in text.splitlines():
                    emit(f'{BL}[{ticket_id}]{R} {line}')

            elif btype == 'tool_use':
                name = block.get('name', '')
                inp  = block.get('input', {})
                hint = ''
                if name in ('Bash', 'bash'):
                    cmd = (inp.get('command') or '')[:80]
                    hint = f'  {DM}{cmd}{R}'
                elif name.startswith('mcp__chrome'):
                    short = name.replace('mcp__chrome-devtools__', '')
                    hint  = f'  {DM}{short}{R}'
                elif name in ('Read', 'Edit', 'Write', 'Glob', 'Grep'):
                    path = inp.get('file_path') or inp.get('path') or inp.get('pattern') or ''
                    hint = f'  {DM}{path}{R}'
                elif name == 'Agent':
                    desc = inp.get('description') or inp.get('subagent_type') or ''
                    hint = f'  {DM}{desc}{R}'
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

# ── Stage-specific: post-pass build check ────────────────────────────────────

run_build_check() {
    local ticket_id="$1"
    local log_file="$2"

    # Resolve branch name
    local branch=""
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/feat/${ticket_id}"; then
        branch="feat/${ticket_id}"
    elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/fix/${ticket_id}"; then
        branch="fix/${ticket_id}"
    else
        branch=$(git -C "$REPO_ROOT" branch -r \
            | grep -E "(feat|fix)/${ticket_id}$" | head -1 \
            | sed 's|origin/||' | tr -d ' ')
    fi

    if [[ -z "$branch" ]]; then
        log WARN "Build check: branch not found for ${ticket_id} — skipping"
        return 0
    fi

    # Count Rust source / manifest changes introduced by the branch
    local rust_changes
    rust_changes=$(git -C "$REPO_ROOT" diff --name-only "develop...${branch}" 2>/dev/null \
        | grep -cE '\.(rs|toml)$' || echo 0)

    if [[ "$rust_changes" -eq 0 ]]; then
        log INFO "Build check: no Rust changes in ${branch} — skipping"
        return 0
    fi

    log INFO "Build check: ${rust_changes} Rust file(s) changed in ${branch} — running cargo build..."

    # Prefer the existing review worktree; create a temp one if needed
    local build_dir="${REPO_ROOT}/../worktrees/${branch}"
    local tmp_wt=""
    if [[ ! -d "$build_dir" ]]; then
        tmp_wt="${REPO_ROOT}/../worktrees-buildcheck/${ticket_id}"
        mkdir -p "$(dirname "$tmp_wt")"
        if git -C "$REPO_ROOT" worktree add "$tmp_wt" "$branch" 2>/dev/null; then
            build_dir="$tmp_wt"
        else
            log WARN "Build check: cannot create worktree — skipping"
            return 0
        fi
    fi

    local build_ok=0
    (
        cd "$build_dir"
        cargo build -j 2 --profile dev-fast --workspace 2>&1
    ) | tee -a "$log_file" | tail -20 || build_ok=1

    # Clean up temp worktree
    if [[ -n "$tmp_wt" ]]; then
        git -C "$REPO_ROOT" worktree remove --force "$tmp_wt" 2>/dev/null || true
        git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    fi

    if [[ $build_ok -ne 0 ]]; then
        log ERROR "Build check FAILED for ${ticket_id}"
        return 1
    fi

    log OK "Build check passed for ${ticket_id}"
    return 0
}

# ── Stage-specific: verdict + build-check post-processing ─────────────────────

stage_print_completion_log() {
    local ticket_id="$1"
    local exit_code="$2"
    local ended_at; ended_at=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ $exit_code -eq 0 ]]; then
        log OK "✓ Review session ended cleanly for $ticket_id  ($ended_at)"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi
}

stage_postprocess_ticket() {
    local ticket_id="$1"
    local log_file="$2"
    local exit_code="$3"
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"

    # Determine verdict from log
    local verdict="unknown"
    if python3 - < "$log_file" 2>/dev/null << 'PYEOF' | grep -qi "pass"; then
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
        verdict="PASS"
    elif python3 - < "$log_file" 2>/dev/null << 'PYEOF' | grep -qi "fail\|changes required"; then
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
        verdict="FAIL"
    fi

    # Post-pass build check
    if [[ "$verdict" == "PASS" ]]; then
        if ! run_build_check "$ticket_id" "$log_file"; then
            log ERROR "Build errors detected — overriding PASS to FAIL for $ticket_id"
            verdict="BUILD_FAIL"

            if [[ -n "${LINEAR_API_KEY:-}" ]]; then
                local changes_req_id
                changes_req_id=$(curl -sf \
                    -H "Authorization: ${LINEAR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d "{\"query\":\"{ workflowStates(filter:{team:{key:{eq:\\\"${LINEAR_TEAM_KEY}\\\"}},name:{eq:\\\"Changes Required\\\"}}) { nodes { id } } }\"}" \
                    https://api.linear.app/graphql 2>/dev/null \
                    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['workflowStates']['nodes'][0]['id'])" 2>/dev/null || true)

                local ticket_gql_id
                ticket_gql_id=$(curl -sf \
                    -H "Authorization: ${LINEAR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${team_key}\\\"}},number:{eq:${issue_num}}}) { nodes { id } } }\"}" \
                    https://api.linear.app/graphql 2>/dev/null \
                    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['issues']['nodes'][0]['id'])" 2>/dev/null || true)

                if [[ -n "$changes_req_id" && -n "$ticket_gql_id" ]]; then
                    curl -sf \
                        -H "Authorization: ${LINEAR_API_KEY}" \
                        -H "Content-Type: application/json" \
                        -d "{\"query\":\"mutation { issueUpdate(id:\\\"${ticket_gql_id}\\\", input:{stateId:\\\"${changes_req_id}\\\"}) { success } }\"}" \
                        https://api.linear.app/graphql > /dev/null 2>&1 || true

                    curl -sf \
                        -H "Authorization: ${LINEAR_API_KEY}" \
                        -H "Content-Type: application/json" \
                        -d "{\"query\":\"mutation { commentCreate(input:{issueId:\\\"${ticket_gql_id}\\\", body:\\\"## Build Check Failed ❌\\\\n\\\\nThe autonomous review agent detected compile errors after the code review passed.\\\\n\\\\n**Action required:** Fix the build errors then re-submit for review.\\\\n\\\\nCheck the review log for the full \`cargo build\` output.\\\"}) { success } }\"}" \
                        https://api.linear.app/graphql > /dev/null 2>&1 || true

                    log INFO "Linear ticket $ticket_id moved back to Changes Required"
                fi
            fi
        fi
    fi

    case "$verdict" in
        PASS)
            echo ""
            echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════╗${RESET}"
            echo -e "${GREEN}${BOLD}  ║  ✅  PASS — ticket moved to Human Review             ║${RESET}"
            echo -e "${GREEN}${BOLD}  ║  Verify at http://localhost:8105 then /ticket-merge   ║${RESET}"
            echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════╝${RESET}"
            echo ""
            log PASS "Human verification required for $ticket_id — check Linear + http://localhost:8105"
            ;;
        BUILD_FAIL)
            echo ""
            echo -e "${RED}${BOLD}  ╔══════════════════════════════════════════════════════╗${RESET}"
            echo -e "${RED}${BOLD}  ║  🔨  BUILD FAIL — compile errors found after review  ║${RESET}"
            echo -e "${RED}${BOLD}  ║  Ticket moved back to Changes Required               ║${RESET}"
            echo -e "${RED}${BOLD}  ╚══════════════════════════════════════════════════════╝${RESET}"
            echo ""
            log FAIL "Build errors for $ticket_id — moved to Changes Required"
            ;;
        FAIL)
            echo ""
            echo -e "${RED}${BOLD}  ╔══════════════════════════════════════════════════════╗${RESET}"
            echo -e "${RED}${BOLD}  ║  ❌  FAIL — ticket moved to Changes Required         ║${RESET}"
            echo -e "${RED}${BOLD}  ║  See the Linear comment for full findings            ║${RESET}"
            echo -e "${RED}${BOLD}  ╚══════════════════════════════════════════════════════╝${RESET}"
            echo ""
            log FAIL "Review failed for $ticket_id — moved to Changes Required"
            ;;
        *)
            log WARN "Verdict unclear for $ticket_id — check log"
            ;;
    esac
}

# ── Stage-specific: review has NO post-exit revert ────────────────────────────

stage_post_exit_revert() {
    :
}

# ── Stage-specific: summary prompt ────────────────────────────────────────────

stage_build_summary_prompt() {
    local ticket_id="$1"
    cat << PROMPT_EOF
Below is the raw output from reviewing Linear ticket ${ticket_id} via /ticket-code-review.

Write a concise per-phase summary of what actually happened. Use ONLY phases that ran. Format each line as:

**Phase N — [Name]:** <1-2 sentence conclusion>

Phases to cover if they ran:
- Phase 0 — Locate Branch: branch found or not, source (comment vs git)
- Phase 1 — Create Review Worktree: worktree created or resumed
- Phase 2 — Understand Implementation: files changed, commits, acceptance criteria parsed
- Phase 3 — Code Review: key findings with file:line refs, or no issues found
- Phase 4 — Tests: suites run, pass/fail counts, any new tests written
- Phase 5 — Visual Proof: screenshots or API files captured, uploaded to Linear
- Phase 6 — Verdict: PASS ✅ or FAIL ❌ with the specific reason
- Phase 7 — Status Update: what Linear status the ticket was moved to
- Phase 8 — Hand Off: cleanup done or human verification requested

End with a one-line overall outcome: PASS or FAIL with the key reason.
Be factual. No filler.
PROMPT_EOF
}

# ── Stage-specific: colorize review summary (PASS=green, FAIL=red, else cyan) ─

_colorize_summary_lines() {
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "PASS|✅"; then
            echo -e "${GREEN}  ${line}${RESET}"
        elif echo "$line" | grep -qiE "FAIL|❌"; then
            echo -e "${RED}  ${line}${RESET}"
        else
            echo -e "${CYAN}  ${line}${RESET}"
        fi
    done
}

# ── Stage-specific: actionable check ─────────────────────────────────────────

stage_still_actionable() {
    local ticket_id="$1"
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1
    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${team_key}\\\"}},number:{eq:${issue_num}}}) { nodes { state { name } } } }\"}" \
        https://api.linear.app/graphql 2>/dev/null)
    local state_name
    state_name=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
nodes = data.get('data', {}).get('issues', {}).get('nodes', [])
print(nodes[0]['state']['name'] if nodes else '')
" <<< "$response" 2>/dev/null)
    [[ "$state_name" == "Code Review" ]]
}

run_main_loop "$@"
