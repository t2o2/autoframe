#!/usr/bin/env bash
# autonomous-agent-planning.sh
#
# Polls Linear for "Research Approved" tickets, then creates implementation plans for them
# one-by-one using /ticket-plan. Shows live streaming output with real-time
# phase banners and a structured per-phase summary at the end of each ticket.
#
# Usage:
#   ./scripts/autonomous-agent-planning.sh [--poll-interval <seconds>] [--once] [--reset]
#
# Flags:
#   --poll-interval <n>   Seconds between polls when idle (default: 60)
#   --once                Process one ticket and exit (useful for testing)
#   --reset               Clear the processed-tickets cache and start fresh

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/autonomous-planning-logs"
PROCESSED_FILE="/tmp/autonomous-planning-processed.txt"

# Load LINEAR_API_KEY from .env if not already set
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LINEAR_API_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
    LINEAR_API_KEY="$(grep -E '^LINEAR_API_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi

POLL_INTERVAL=60
HEARTBEAT_INTERVAL=30
TICKET_TIMEOUT=1800   # max seconds for a single ticket (default 30 min)
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

PROCESSOR="/tmp/planning-processor-$$.py"

cat > "$PROCESSOR" << 'PYEOF'
#!/usr/bin/env python3
import sys, json, re, os

ticket_id = sys.argv[1] if len(sys.argv) > 1 else "GYL-?"
heartbeat_file = sys.argv[2] if len(sys.argv) > 2 else None

R  = '\033[0m'
BL = '\033[0;34m'
MG = '\033[0;35m'
GN = '\033[0;32m'
RD = '\033[0;31m'
BD = '\033[1m'
DM = '\033[2m'
YL = '\033[1;33m'

PHASE_RE = re.compile(r'##\s+(Phase\s+\d+[ab]?\s*[—–-]+\s*[^\n]+)', re.IGNORECASE)

current_phase = ""

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
                m = PHASE_RE.search(text)
                if m:
                    new_phase = m.group(1).strip()
                    new_phase = re.sub(r'\s*[—–-]+\s*', ' — ', new_phase, count=1)
                    if new_phase != current_phase:
                        emit(f'\n{MG}{"━"*3} ▶ {BD}{new_phase}{R}{MG} {"━"*28}{R}')
                        current_phase = new_phase
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
                emit(f'{DM}[{ticket_id}] 📐  {name}{hint}{R}')

    elif etype == 'tool_use':
        name = event.get('name', '')
        if name:
            emit(f'{DM}[{ticket_id}] 📐  {name}{R}')

    elif etype == 'result':
        if event.get('is_error'):
            err = str(event.get('result', 'unknown'))[:300]
            emit(f'{RD}[{ticket_id}] ❌  Error: {err}{R}')

    elif etype == 'system':
        subtype = event.get('subtype', '')
        if subtype == 'init':
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
        *)     color="$RESET"   ;;
    esac
    echo -e "${color}[$ts] [$level] $*${RESET}"
    echo "[$ts] [$level] $*" >> "$LOG_DIR/agent.log"
}

divider() {
    local char="${1:-─}"
    local label="${2:-}"
    if [[ -n "$label" ]]; then
        echo -e "${BLUE}${char}${char}${char} ${BOLD}${label}${RESET}${BLUE} $(printf '%*s' $((58 - ${#label})) '' | tr ' ' "$char")${RESET}"
    else
        echo -e "${BLUE}$(printf '%*s' 62 '' | tr ' ' "$char")${RESET}"
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
            printf "${DIM}[$(date '+%H:%M:%S')] ⏳  Still planning ${BOLD}%s${RESET}${DIM}... %dm%ds elapsed${RESET}\n" \
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
        log WARN "Nothing to summarize (empty log)"
        return
    fi

    echo ""
    divider "═" "Phase Summary — $ticket_id"
    echo ""

    printf '%s' "$full_text" \
    | head -c 18000 \
    | claude --dangerously-skip-permissions --no-session-persistence -p \
        "Below is the raw output from planning Linear ticket ${ticket_id} via /ticket-plan.

Write a concise per-phase summary of what actually happened. Use ONLY phases that ran. Format each on its own line:

**Phase 1 — Fetch Ticket & Research:** <ticket title, research comment found or absent>
**Phase 2 — Fill Research Gaps:** <sub-agents spawned, gaps filled>
**Phase 3 — Resolve Key Decisions:** <decisions made, any human judgment comments posted>
**Phase 4 — Write Implementation Plan:** <number of phases planned, key files identified, scope estimate>
**Phase 5 — Post Plan & Transition:** <comment posted, status moved to Pending Plan Approval>

Skip phases that did not run. Be factual. No filler.

---
$(cat)" \
    2>/dev/null \
    | while IFS= read -r line; do
        echo -e "${GREEN}  ${line}${RESET}"
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

fetch_pending_tickets() {
    log INFO "Querying Linear for 'Research Approved' tickets..."

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        log WARN "LINEAR_API_KEY not set — cannot query Linear"
        echo "NONE"
        return
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ issues(filter:{team:{key:{eq:\"GYL\"}},state:{name:{in:[\"Research Approved\"]}}}) { nodes { identifier } } }"}' \
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

is_processed()   { grep -qxF "$1" "$PROCESSED_FILE" 2>/dev/null; }
mark_processed() { echo "$1" >> "$PROCESSED_FILE"; }

# ── Linear status check ───────────────────────────────────────────────────────

ticket_still_actionable() {
    local ticket_id="$1"

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        return 1
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{identifier:{eq:\\\"${ticket_id}\\\"}}) { nodes { state { name } } } }\"}" \
        https://api.linear.app/graphql 2>/dev/null)

    local state_name
    state_name=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
nodes = data.get('data', {}).get('issues', {}).get('nodes', [])
print(nodes[0]['state']['name'] if nodes else '')
" <<< "$response" 2>/dev/null)

    [[ "$state_name" == "Research Approved" ]]
}

# ── Stale-claim helpers ───────────────────────────────────────────────────────

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

STALE_THRESHOLD=1800   # 30 minutes — no stream output → revert
STALE_WATCHDOG_PID=""

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

# Revert stale claims left by prior crashed agent instances
revert_stale_claims() {
    local hb_prefix="$1"    # e.g. "plan"
    local lock_prefix="$2"  # e.g. "plan"
    local stale_secs="$STALE_THRESHOLD"
    local hb ticket_id revert_state mtime age
    # nullglob: skip silently if no files match
    for hb in /tmp/${hb_prefix}-heartbeat-*.txt; do
        [[ -f "$hb" ]] || continue
        ticket_id=$(basename "$hb" .txt | sed "s/${hb_prefix}-heartbeat-//")
        revert_state=$(cat "$hb" 2>/dev/null) || continue
        mtime=$(stat -f %m "$hb" 2>/dev/null) || continue
        age=$(( $(date +%s) - mtime ))
        if (( age > stale_secs )); then
            log WARN "Stale claim: $ticket_id (${age}s old, revert→'$revert_state')"
            revert_ticket_status "$ticket_id" "$revert_state"
            rm -f "$hb"
            rmdir "/tmp/${lock_prefix}-lock-${ticket_id}" 2>/dev/null || true
        else
            log INFO "Active claim file found: $ticket_id (${age}s, within threshold)"
        fi
    done
}

# ── Ticket processor ──────────────────────────────────────────────────────────

process_ticket() {
    local ticket_id="$1"
    local log_file="$LOG_DIR/${ticket_id}-$(date '+%Y%m%d-%H%M%S').log"
    local exit_code=0

    local lock_dir="/tmp/plan-lock-${ticket_id}"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        log INFO "  $ticket_id is locked by another local agent — skipping"
        return
    fi
    local HB_FILE="/tmp/plan-heartbeat-${ticket_id}.txt"
    echo "Research Approved" > "$HB_FILE"
    trap "rmdir '$lock_dir' 2>/dev/null || true; rm -f '${HB_FILE}'" RETURN

    divider "═" "Planning: $ticket_id"
    log WORK "Ticket  : $ticket_id"
    log WORK "Log     : $log_file"
    log WORK "Started : $(date '+%Y-%m-%d %H:%M:%S')"
    divider
    echo ""

    start_heartbeat "$ticket_id"

    (
        claude --dangerously-skip-permissions \
               --no-session-persistence \
               -p "/ticket-plan $ticket_id" \
               --output-format stream-json \
               --include-partial-messages \
               2>&1
    ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" "$HB_FILE" &
    PIPELINE_PID=$!

    start_stale_watchdog "$ticket_id" "$HB_FILE" "Research Approved" "$PIPELINE_PID"

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

    # Post-exit revert: if ticket still in claimed state, revert it
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local final_state
        final_state=$(get_ticket_state "$ticket_id") || final_state=""
        if [[ "$final_state" == "Planning" ]]; then
            log WARN "$ticket_id still in 'Planning' after pipeline exit — reverting to 'Research Approved'"
            revert_ticket_status "$ticket_id" "Research Approved"
        fi
    fi

    stop_heartbeat

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log OK  "✓ Plan complete : $ticket_id  ($(date '+%H:%M:%S'))"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi

    summarize_phases "$ticket_id" "$log_file"

    if ticket_still_actionable "$ticket_id"; then
        log WARN "  $ticket_id still in Research Approved — will retry next poll (not cached)"
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
    log INFO "Planning agent stopped (PID $$) — $(date '+%Y-%m-%d %H:%M:%S')"
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
    log INFO "  Autonomous Planning Agent"
    log INFO "  Picks up: Research Approved → Planning → Pending Plan Approval"
    log INFO "  Poll interval  : ${POLL_INTERVAL}s"
    log INFO "  Heartbeat      : ${HEARTBEAT_INTERVAL}s"
    log INFO "  Session logs   : $LOG_DIR/"
    log INFO "  Processed cache: $PROCESSED_FILE"
    divider "═"
    echo ""

    local cycle=0

    while true; do
        revert_stale_claims "plan" "plan"
        cycle=$((cycle + 1))
        log INFO "Poll #${cycle} — $(date '+%Y-%m-%d %H:%M:%S')"

        local raw; raw=$(fetch_pending_tickets)
        local ticket_ids; ticket_ids=$(parse_ticket_ids "$raw") || true

        if [[ -z "$ticket_ids" ]]; then
            log INFO "No Research Approved tickets. Sleeping ${POLL_INTERVAL}s..."
            interruptible_sleep "$POLL_INTERVAL"
            continue
        fi

        local pending=()
        while IFS= read -r tid; do
            if is_processed "$tid"; then
                log INFO "  Skip (done this session): $tid"
            else
                pending+=("$tid")
            fi
        done <<< "$ticket_ids"

        if [[ ${#pending[@]} -eq 0 ]]; then
            log INFO "All tickets already processed this session. Sleeping ${POLL_INTERVAL}s..."
            interruptible_sleep "$POLL_INTERVAL"
            continue
        fi

        log INFO "Found ${#pending[@]} actionable ticket(s): ${pending[*]}"
        echo ""

        for ticket_id in "${pending[@]}"; do
            process_ticket "$ticket_id"
            echo ""
            if $RUN_ONCE; then
                log INFO "--once: stopping after first ticket"
                exit 0
            fi
        done

        log INFO "Cycle #${cycle} done. Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
