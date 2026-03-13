#!/usr/bin/env bash
# autonomous-approve-agent.sh
#
# Polls Linear for "Merging" tickets, then approves them one-by-one using
# /ticket-approve. Shows live streaming output with real-time phase banners
# and a structured per-phase summary at the end of each ticket.
#
# Usage:
#   ./scripts/autonomous-approve-agent.sh [--poll-interval <seconds>] [--once] [--reset]
#
# Flags:
#   --poll-interval <n>   Seconds between polls when idle (default: 60)
#   --once                Approve one ticket and exit (useful for testing)
#   --reset               Clear the processed-tickets cache and start fresh

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/autonomous-approve-logs"
PROCESSED_FILE="/tmp/autonomous-approve-processed.txt"

# Load LINEAR_API_KEY from .env if not already set
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LINEAR_API_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
    LINEAR_API_KEY="$(grep -E '^LINEAR_API_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi

POLL_INTERVAL=60
HEARTBEAT_INTERVAL=30
TICKET_TIMEOUT=1800   # max seconds for a single ticket approval (default 30 min)
RUN_ONCE=false
RESET_CACHE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --once)          RUN_ONCE=true;       shift   ;;
        --reset)         RESET_CACHE=true;    shift   ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

mkdir -p "$LOG_DIR"
if $RESET_CACHE; then > "$PROCESSED_FILE"; echo "Cache cleared."; fi
touch "$PROCESSED_FILE"

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Stream processor ──────────────────────────────────────────────────────────
# Written to a temp file so it can be used in a pipeline.
# Detects Phase transitions, shows tool-call hints, and surfaces merge result.

PROCESSOR="/tmp/approve-processor-$$.py"

cat > "$PROCESSOR" << 'PYEOF'
#!/usr/bin/env python3
"""
Reads Claude stream-json from stdin.
Prints formatted output with real-time Phase transition banners and surfaces
the merge result from /ticket-approve output.
Usage: python3 <script> <ticket_id>
"""
import sys, json, re, os

ticket_id = sys.argv[1] if len(sys.argv) > 1 else "GYL-?"
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
DONE_RE   = re.compile(r'/ticket-approve.*complete|✅.*complete|merged.*→.*develop|Repository is clean', re.IGNORECASE)
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
                elif name.startswith('mcp__linear'):
                    short = name.replace('mcp__linear-server__', '')
                    hint  = f'  {DM}{short}{R}'
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

# ── Logging ───────────────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color
    case "$level" in
        INFO)  color="$CYAN"    ;;
        OK)    color="$GREEN"   ;;
        WARN)  color="$YELLOW"  ;;
        ERROR) color="$RED"     ;;
        WORK)  color="$MAGENTA" ;;
        BEAT)  color="$DIM"     ;;
        DONE)  color="$GREEN"   ;;
        FAIL)  color="$RED"     ;;
        *)     color="$RESET"   ;;
    esac
    echo -e "${color}[$ts] [$level] $*${RESET}"
    echo "[$ts] [$level] $*" >> "$LOG_DIR/agent.log"
}

divider() {
    local char="${1:-─}"
    local label="${2:-}"
    if [[ -n "$label" ]]; then
        echo -e "${GREEN}${char}${char}${char} ${BOLD}${label}${RESET}${GREEN} $(printf '%*s' $((58 - ${#label})) '' | tr ' ' "$char")${RESET}"
    else
        echo -e "${GREEN}$(printf '%*s' 62 '' | tr ' ' "$char")${RESET}"
    fi
}

# ── Heartbeat ─────────────────────────────────────────────────────────────────

HEARTBEAT_PID=""

start_heartbeat() {
    local ticket_id="$1"
    (
        local elapsed=0
        while true; do
            sleep "$HEARTBEAT_INTERVAL"
            elapsed=$((elapsed + HEARTBEAT_INTERVAL))
            printf "${DIM}[$(date '+%H:%M:%S')] ⏳  Still approving ${BOLD}%s${RESET}${DIM}... %dm%ds elapsed${RESET}\n" \
                "$ticket_id" $((elapsed / 60)) $((elapsed % 60))
        done
    ) &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "$HEARTBEAT_PID" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# ── Stale-claim helpers ───────────────────────────────────────────────────────

STALE_THRESHOLD=1800   # 30 minutes — no stream output → revert
STALE_WATCHDOG_PID=""

get_ticket_state() {
    local ticket_id="$1"
    [[ -z "${LINEAR_API_KEY:-}" ]] && echo "" && return
    curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{identifier:{eq:\\\"${ticket_id}\\\"}}) { nodes { state { name } } } }\"}" \
        https://api.linear.app/graphql 2>/dev/null \
    | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
n=d.get('data',{}).get('issues',{}).get('nodes',[])
print(n[0]['state']['name'] if n else '')
" 2>/dev/null || true
}

revert_ticket_status() {
    local ticket_id="$1"
    local target_state="$2"
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1
    local issue_resp uuid states_resp state_id
    issue_resp=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{identifier:{eq:\\\"${ticket_id}\\\"}}) { nodes { id } } }\"}" \
        https://api.linear.app/graphql 2>/dev/null) || return 1
    uuid=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
n=d.get('data',{}).get('issues',{}).get('nodes',[])
print(n[0]['id'] if n else '')
" <<< "$issue_resp" 2>/dev/null)
    [[ -z "$uuid" ]] && log WARN "revert: UUID not found for $ticket_id" && return 1
    states_resp=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ teams(filter:{key:{eq:\"GYL\"}}) { nodes { states { nodes { id name } } } } }"}' \
        https://api.linear.app/graphql 2>/dev/null) || return 1
    state_id=$(python3 -c "
import json,sys
target=sys.argv[1]
d=json.loads(sys.stdin.read())
for team in d.get('data',{}).get('teams',{}).get('nodes',[]):
    for s in team.get('states',{}).get('nodes',[]):
        if s['name']==target:
            print(s['id']); exit()
" "$target_state" <<< "$states_resp" 2>/dev/null)
    [[ -z "$state_id" ]] && log WARN "revert: state '$target_state' not found" && return 1
    curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"mutation { issueUpdate(id: \\\"${uuid}\\\", input: { stateId: \\\"${state_id}\\\" }) { success } }\"}" \
        https://api.linear.app/graphql >/dev/null 2>&1 || return 1
    log OK "Reverted $ticket_id → '$target_state'"
}

start_stale_watchdog() {
    local ticket_id="$1"
    local hb_file="$2"
    local revert_state="$3"
    local pipe_pid="$4"
    (
        while [[ -f "$hb_file" ]]; do
            sleep 60
            [[ ! -f "$hb_file" ]] && exit 0
            local mtime age
            mtime=$(stat -f %m "$hb_file" 2>/dev/null) || exit 0
            age=$(( $(date +%s) - mtime ))
            if (( age > STALE_THRESHOLD )); then
                printf "${YELLOW}[$(date '+%H:%M:%S')] ⚠  %s inactive %ds — reverting to '%s'${RESET}\n" \
                    "$ticket_id" "$age" "$revert_state"
                revert_ticket_status "$ticket_id" "$revert_state"
                rm -f "$hb_file"
                kill -- "-$(ps -o pgid= -p "$pipe_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null \
                    || kill "$pipe_pid" 2>/dev/null || true
                exit 0
            fi
        done
    ) &
    STALE_WATCHDOG_PID=$!
}

stop_stale_watchdog() {
    if [[ -n "${STALE_WATCHDOG_PID:-}" ]]; then
        kill "$STALE_WATCHDOG_PID" 2>/dev/null || true
        wait "$STALE_WATCHDOG_PID" 2>/dev/null || true
        STALE_WATCHDOG_PID=""
    fi
}

# Revert stale claims left by prior crashed agent instances and remove their locks.
revert_stale_claims() {
    local hb_prefix="$1"
    local lock_prefix="$2"
    local hb ticket_id revert_state mtime age
    for hb in /tmp/${hb_prefix}-heartbeat-*.txt; do
        [[ -f "$hb" ]] || continue
        ticket_id=$(basename "$hb" .txt | sed "s/${hb_prefix}-heartbeat-//")
        revert_state=$(cat "$hb" 2>/dev/null) || continue
        mtime=$(stat -f %m "$hb" 2>/dev/null) || continue
        age=$(( $(date +%s) - mtime ))
        if (( age > STALE_THRESHOLD )); then
            log WARN "Stale claim: $ticket_id (${age}s old, revert→'$revert_state')"
            revert_ticket_status "$ticket_id" "$revert_state"
            rm -f "$hb"
            rmdir "/tmp/${lock_prefix}-lock-${ticket_id}" 2>/dev/null || true
        else
            log INFO "Active claim file found: $ticket_id (${age}s, within threshold)"
        fi
    done
}

# ── Phase summary ─────────────────────────────────────────────────────────────

summarize_phases() {
    local ticket_id="$1"
    local log_file="$2"

    local full_text
    full_text=$(python3 - < "$log_file" 2>/dev/null << 'PYEOF'
import sys, json
for raw in sys.stdin:
    raw = raw.rstrip()
    if not raw:
        continue
    try:
        e = json.loads(raw)
    except:
        continue
    if e.get('type') == 'assistant':
        for b in (e.get('message') or {}).get('content', []):
            if b.get('type') == 'text':
                print(b['text'], end='')
PYEOF
    )

    if [[ -z "$full_text" ]]; then
        log WARN "Nothing to summarize"
        return
    fi

    echo ""
    divider "═" "Phase Summary — $ticket_id"
    echo ""

    printf '%s' "$full_text" \
    | head -c 18000 \
    | claude --dangerously-skip-permissions --no-session-persistence -p \
        "Below is the raw output from approving Linear ticket ${ticket_id} via /ticket-approve.

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

---
$(cat)" \
    2>/dev/null \
    | while IFS= read -r line; do
        if echo "$line" | grep -qiE "MERGED|✅"; then
            echo -e "${GREEN}  ${line}${RESET}"
        elif echo "$line" | grep -qiE "FAILED|❌"; then
            echo -e "${RED}  ${line}${RESET}"
        else
            echo -e "${CYAN}  ${line}${RESET}"
        fi
    done \
    || log WARN "Summary generation failed"

    echo ""
    divider "═"
}

# ── Interruptible sleep ───────────────────────────────────────────────────────

interruptible_sleep() {
    sleep "$1" &
    wait $!
}

# ── Linear query ──────────────────────────────────────────────────────────────

fetch_merging_tickets() {
    log INFO "Querying Linear for 'Merging' tickets..."

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        log WARN "LINEAR_API_KEY not set — cannot query Linear"
        echo "NONE"
        return
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ issues(filter:{team:{key:{eq:\"GYL\"}},state:{name:{eq:\"Merging\"}}}) { nodes { identifier } } }"}' \
        https://api.linear.app/graphql 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        log WARN "Linear API call failed — will retry next cycle"
        echo "NONE"
        return
    fi

    local result
    result=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
nodes = data.get('data', {}).get('issues', {}).get('nodes', [])
ids = [n['identifier'] for n in nodes]
print('\n'.join(ids) if ids else 'NONE')
" <<< "$response")

    log INFO "fetch result: $result"
    echo "$result"
}

parse_ticket_ids() {
    echo "$1" | grep -oE 'GYL-[0-9]+' | sort -t- -k2 -n | uniq
}

is_processed()     { grep -qxF "$1" "$PROCESSED_FILE" 2>/dev/null; }
mark_processed()   { echo "$1" >> "$PROCESSED_FILE"; }
unmark_processed() { sed -i '' "/^${1}$/d" "$PROCESSED_FILE" 2>/dev/null || true; }

# Remove cached tickets that are no longer in Merging status.
# Called at the start of each poll cycle so stale entries don't block re-processing.
prune_cache() {
    local cached
    cached=$(cat "$PROCESSED_FILE" 2>/dev/null | grep -oE 'GYL-[0-9]+' || true)
    [[ -z "$cached" ]] && return

    while IFS= read -r tid; do
        if ! ticket_still_merging "$tid"; then
            unmark_processed "$tid"
            log INFO "  Evicted from cache (no longer Merging): $tid"
        fi
    done <<< "$cached"
}

# ── Linear status check ───────────────────────────────────────────────────────
# Returns 0 (still Merging) or 1 (moved on to Done / etc.)

ticket_still_merging() {
    local ticket_id="$1"

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        # No API key — assume still merging to avoid false cache
        return 0
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{identifier:{eq:\\\"${ticket_id}\\\"}}) { nodes { state { name } } } }\"}" \
        https://api.linear.app/graphql 2>/dev/null)

    # If curl failed or returned empty, assume still merging to avoid false cache
    if [[ $? -ne 0 || -z "$response" ]]; then
        log WARN "  Linear status check failed for $ticket_id — assuming still Merging"
        return 0
    fi

    local state_name
    state_name=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
nodes = data.get('data', {}).get('issues', {}).get('nodes', [])
print(nodes[0]['state']['name'] if nodes else '')
" <<< "$response" 2>/dev/null)

    [[ "$state_name" == "Merging" ]]
}

# ── Ticket approver ───────────────────────────────────────────────────────────

approve_ticket() {
    local ticket_id="$1"
    local log_file="$LOG_DIR/${ticket_id}-$(date '+%Y%m%d-%H%M%S').log"
    local exit_code=0

    # ── Per-ticket lock (parallel-safe, macOS/Linux) ─────────────────────────
    local lock_dir="/tmp/approve-lock-${ticket_id}"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        log INFO "  $ticket_id is locked by another local agent — skipping"
        return
    fi
    local HB_FILE="/tmp/approve-heartbeat-${ticket_id}.txt"
    echo "Merging" > "$HB_FILE"
    # Release lock and heartbeat file on function exit (success, error, or return)
    trap "rmdir '$lock_dir' 2>/dev/null || true; rm -f '${HB_FILE}'" RETURN

    divider "═" "Approving: $ticket_id"
    log WORK "Ticket  : $ticket_id"
    log WORK "Log     : $log_file"
    log WORK "Started : $(date '+%Y-%m-%d %H:%M:%S')"
    divider
    echo ""

    start_heartbeat "$ticket_id"

    (
        claude --dangerously-skip-permissions \
               --no-session-persistence \
               -p "/ticket-approve $ticket_id" \
               --output-format stream-json \
               --include-partial-messages \
               2>&1
    ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" "$HB_FILE" &
    PIPELINE_PID=$!

    start_stale_watchdog "$ticket_id" "$HB_FILE" "Merging" "$PIPELINE_PID"

    # Watchdog kills the pipeline group after TICKET_TIMEOUT seconds
    ( sleep "$TICKET_TIMEOUT" && \
      kill -- "-$(ps -o pgid= -p "$PIPELINE_PID" 2>/dev/null | tr -d ' ')" 2>/dev/null ) &
    WATCHDOG_PID=$!

    wait "$PIPELINE_PID"
    exit_code=$?
    PIPELINE_PID=""
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true

    stop_stale_watchdog
    rm -f "$HB_FILE"

    stop_heartbeat

    echo ""
    local ended_at; ended_at=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ $exit_code -eq 0 ]]; then
        log OK "✓ Approve session ended cleanly for $ticket_id  ($ended_at)"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi

    # ── Determine outcome from log ────────────────────────────────────────────
    local outcome="unknown"
    if python3 - < "$log_file" 2>/dev/null << 'PYEOF' | grep -qiE "ticket-approve.*complete|repository is clean|merged.*→"; then
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

    # ── Per-phase summary ─────────────────────────────────────────────────────
    summarize_phases "$ticket_id" "$log_file"

    # ── Conditional cache: only skip on future polls if Linear status moved on ─
    if ticket_still_merging "$ticket_id"; then
        log WARN "  $ticket_id still 'Merging' — will retry next poll (not cached)"
    else
        mark_processed "$ticket_id"
        log INFO "  $ticket_id status advanced — cached to skip future polls"
    fi

    echo ""
    log INFO "Context cleared. Resuming poll loop..."
    divider
}

# ── Signal handling ───────────────────────────────────────────────────────────

PIPELINE_PID=""
SHUTTING_DOWN=false

on_interrupt() {
    $SHUTTING_DOWN && return
    SHUTTING_DOWN=true
    trap '' EXIT INT TERM
    echo ""
    log WARN "Interrupted — shutting down..."
    stop_heartbeat
    stop_stale_watchdog
    if [[ -n "$PIPELINE_PID" ]]; then
        kill -- "-$(ps -o pgid= -p "$PIPELINE_PID" 2>/dev/null | tr -d ' ')" 2>/dev/null \
            || kill "$PIPELINE_PID" 2>/dev/null || true
    fi
    pkill -P $$ -TERM 2>/dev/null || true
    sleep 0.3
    pkill -P $$ -KILL 2>/dev/null || true
    rm -f "$PROCESSOR"
    log INFO "Approve agent stopped (PID $$) — $(date '+%Y-%m-%d %H:%M:%S')"
    log INFO "Session log : $LOG_DIR/agent.log"
    exit 130
}

on_exit() {
    stop_heartbeat
    rm -f "$PROCESSOR"
}

trap on_interrupt INT TERM
trap on_exit EXIT

# ── Main loop ─────────────────────────────────────────────────────────────────

main() {
    divider "═"
    log INFO "  Autonomous Linear Approve Agent"
    log INFO "  Watching status : Merging"
    log INFO "  Poll interval   : ${POLL_INTERVAL}s"
    log INFO "  Heartbeat       : ${HEARTBEAT_INTERVAL}s"
    log INFO "  Session logs    : $LOG_DIR/"
    log INFO "  Processed cache : $PROCESSED_FILE"
    divider "═"
    echo ""

    local cycle=0

    while true; do
        cycle=$((cycle + 1))
        revert_stale_claims "approve" "approve"
        log INFO "Poll #${cycle} — $(date '+%Y-%m-%d %H:%M:%S')"

        prune_cache

        local raw; raw=$(fetch_merging_tickets)
        local ticket_ids; ticket_ids=$(parse_ticket_ids "$raw") || true

        if [[ -z "$ticket_ids" ]]; then
            log INFO "No 'Merging' tickets. Sleeping ${POLL_INTERVAL}s..."
            interruptible_sleep "$POLL_INTERVAL"
            continue
        fi

        local pending=()
        while IFS= read -r tid; do
            if is_processed "$tid"; then
                # Ticket was cached but Linear returned it again — it cycled back.
                # Evict from cache so it gets reprocessed.
                sed -i '' "/^${tid}$/d" "$PROCESSED_FILE" 2>/dev/null || true
                log INFO "  $tid re-entered polling state — evicted from cache, will reprocess"
                pending+=("$tid")
            else
                pending+=("$tid")
            fi
        done <<< "$ticket_ids"

        if [[ ${#pending[@]} -eq 0 ]]; then
            log INFO "All 'Merging' tickets already processed this session. Sleeping ${POLL_INTERVAL}s..."
            interruptible_sleep "$POLL_INTERVAL"
            continue
        fi

        log INFO "Found ${#pending[@]} ticket(s) to approve: ${pending[*]}"
        echo ""

        for ticket_id in "${pending[@]}"; do
            approve_ticket "$ticket_id"
            echo ""
            if $RUN_ONCE; then
                log INFO "--once: stopping after first approval"
                exit 0
            fi
        done

        log INFO "Cycle #${cycle} done. Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
