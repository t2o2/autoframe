#!/usr/bin/env bash
# autonomous-agent-research-pi.sh
#
# Pi-native version of the process agent.
# Polls Linear for "Plan Approved" and "Changes Required" tickets, then processes
# them one-by-one using the /ticket-process pi prompt template.
#
# Usage:
#   ./scripts/autonomous-agent-research-pi.sh [--poll-interval <seconds>] [--once] [--reset]
#
# Flags:
#   --poll-interval <n>   Seconds between polls when idle (default: 60)
#   --once                Process one ticket and exit (useful for testing)
#   --reset               Clear the processed-tickets cache and start fresh

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/autonomous-research-pi-logs"
PROCESSED_FILE="/tmp/autonomous-research-pi-processed.txt"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LINEAR_API_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
    LINEAR_API_KEY="$(grep -E '^LINEAR_API_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi
if [[ -z "${LINEAR_TEAM_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
    LINEAR_TEAM_KEY="$(grep -E '^LINEAR_TEAM_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi

POLL_INTERVAL=60
HEARTBEAT_INTERVAL=30
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

# ── Stream processor for pi --mode json ──────────────────────────────────────
# Pi emits AgentSessionEvents as JSON lines. We extract:
#   - text_delta events  → printed with ticket prefix
#   - tool_execution_start → tool call hints
#   - Phase banners detected from text content

PROCESSOR="/tmp/pi-ticket-processor-$$.py"

cat > "$PROCESSOR" << 'PYEOF'
#!/usr/bin/env python3
"""
Reads pi --mode json events from stdin.
Prints formatted output with real-time Phase transition banners.
"""
import sys, json, re, os

ticket_id = sys.argv[1] if len(sys.argv) > 1 else "TICKET-?"
heartbeat_file = sys.argv[2] if len(sys.argv) > 2 else None

R  = '\033[0m'
BL = '\033[0;34m'
MG = '\033[0;35m'
GN = '\033[0;32m'
RD = '\033[0;31m'
BD = '\033[1m'
DM = '\033[2m'

PHASE_RE = re.compile(r'##\s+(Phase\s+\d+[ab]?\s*[—–-]+\s*[^\n]+)', re.IGNORECASE)

current_phase = ""
text_buffer = ""

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

    if etype == 'message_update':
        ae = event.get('assistantMessageEvent', {})
        ae_type = ae.get('type', '')

        if ae_type == 'text_delta':
            delta = ae.get('delta', '')
            text_buffer += delta

            # Flush line-by-line
            while '\n' in text_buffer:
                line, text_buffer = text_buffer.split('\n', 1)
                # Detect phase transitions
                m = PHASE_RE.search(line)
                if m:
                    new_phase = m.group(1).strip()
                    new_phase = re.sub(r'\s*[—–-]+\s*', ' — ', new_phase, count=1)
                    if new_phase != current_phase:
                        emit(f'\n{MG}{"━"*3} ▶ {BD}{new_phase}{R}{MG} {"━"*28}{R}')
                        current_phase = new_phase
                emit(f'{BL}[{ticket_id}]{R} {line}')

        elif ae_type == 'text_end':
            # Flush remaining buffer
            if text_buffer:
                for line in text_buffer.splitlines():
                    emit(f'{BL}[{ticket_id}]{R} {line}')
                text_buffer = ""

        elif ae_type == 'toolcall_end':
            tc = ae.get('toolCall', {})
            name = tc.get('name', '')
            args = tc.get('arguments', {})
            hint = ''
            if name == 'bash':
                cmd = (args.get('command') or '')[:80]
                hint = f'  {DM}{cmd}{R}'
            elif name in ('read', 'edit', 'write', 'grep', 'find', 'ls'):
                path = args.get('path') or args.get('file_path') or args.get('pattern') or ''
                hint = f'  {DM}{path}{R}'
            elif name == 'agent_browser':
                ab_args = (args.get('args') or [])
                hint = f'  {DM}{" ".join(str(a) for a in ab_args[:3])}{R}'
            emit(f'{DM}[{ticket_id}] 🔧  {name}{hint}{R}')

    elif etype == 'tool_execution_start':
        name = event.get('toolName', '')
        args = event.get('args', {})
        hint = ''
        if name == 'bash':
            cmd = (args.get('command') or '')[:80]
            hint = f'  {DM}{cmd}{R}'
        elif name in ('read', 'edit', 'write', 'grep', 'find', 'ls'):
            path = args.get('path') or args.get('file_path') or ''
            hint = f'  {DM}{path}{R}'
        elif name == 'agent_browser':
            ab_args = (args.get('args') or [])
            hint = f'  {DM}{" ".join(str(a) for a in ab_args[:3])}{R}'
        emit(f'{DM}[{ticket_id}] 🔧  {name}{hint}{R}')

    elif etype == 'agent_end':
        # Flush any remaining text
        if text_buffer:
            for line in text_buffer.splitlines():
                emit(f'{BL}[{ticket_id}]{R} {line}')
            text_buffer = ""

    elif etype == 'auto_retry_start':
        attempt = event.get('attempt', '?')
        emit(f'{DM}[{ticket_id}] ↺  Auto-retry attempt {attempt}{R}')

    elif etype == 'compaction_start':
        emit(f'{DM}[{ticket_id}] ⚡ Compacting context...{R}')
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
    local hb_file="${2:-}"
    (
        local elapsed=0
        while true; do
            sleep "$HEARTBEAT_INTERVAL"
            elapsed=$((elapsed + HEARTBEAT_INTERVAL))
            [[ -n "$hb_file" && -f "$hb_file" ]] && touch "$hb_file"
            printf "${DIM}[$(date '+%H:%M:%S')] ⏳  Still researching ${BOLD}%s${RESET}${DIM}... %dm%ds elapsed${RESET}\n" \
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

# ── Linear helpers ────────────────────────────────────────────────────────────

linear_gql() {
    local query="$1"
    curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        --data-raw "{\"query\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$query")}" \
        https://api.linear.app/graphql 2>/dev/null
}

fetch_pending_tickets() {
    log INFO "Querying Linear for 'Plan Approved' and 'Change Required' tickets..."

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        log WARN "LINEAR_API_KEY not set — cannot query Linear"
        echo "NONE"
        return
    fi

    local response
    response=$(linear_gql "{ issues(filter:{team:{key:{eq:\"${LINEAR_TEAM_KEY}\"}},state:{name:{in:[\"Plan Approved\",\"Change Required\"]}}}) { nodes { identifier } } }")

    if [[ -z "$response" ]]; then
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

get_ticket_state() {
    local ticket_id="$1"
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"
    [[ -z "${LINEAR_API_KEY:-}" ]] && echo "" && return
    linear_gql "{ issues(filter:{team:{key:{eq:\"${team_key}\"}},number:{eq:${issue_num}}}) { nodes { state { name } } } }" \
    | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
n=d.get('data',{}).get('issues',{}).get('nodes',[])
print(n[0]['state']['name'] if n else '')
" 2>/dev/null || true
}

revert_ticket_status() {
    local ticket_id="$1"
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"
    local target_state="$2"
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    local uuid
    uuid=$(linear_gql "{ issues(filter:{team:{key:{eq:\"${team_key}\"}},number:{eq:${issue_num}}}) { nodes { id } } }" \
        | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); n=d.get('data',{}).get('issues',{}).get('nodes',[]); print(n[0]['id'] if n else '')" 2>/dev/null)
    [[ -z "$uuid" ]] && log WARN "revert: UUID not found for $ticket_id" && return 1

    local state_id
    state_id=$(linear_gql "{ workflowStates(filter:{team:{key:{eq:\"${LINEAR_TEAM_KEY}\"}}}) { nodes { id name } } }" \
        | python3 -c "
import json,sys
target=sys.argv[1]
d=json.loads(sys.stdin.read())
for s in d.get('data',{}).get('workflowStates',{}).get('nodes',[]):
    if s['name']==target:
        print(s['id']); exit()
" "$target_state" 2>/dev/null)
    [[ -z "$state_id" ]] && log WARN "revert: state '$target_state' not found" && return 1

    linear_gql "mutation { issueUpdate(id: \"${uuid}\", input: { stateId: \"${state_id}\" }) { success } }" >/dev/null
    log OK "Reverted $ticket_id → '$target_state'"
}

ticket_still_actionable() {
    local ticket_id="$1"
    local state
    state=$(get_ticket_state "$ticket_id") || return 1
    [[ "$state" == "Plan Approved" || "$state" == "Change Required" ]]
}

# ── Stale-claim helpers ───────────────────────────────────────────────────────

STALE_THRESHOLD=1800
LINEAR_STALE_THRESHOLD=3600
STALE_WATCHDOG_PID=""
STATUS_WATCHER_PID=""

start_stale_watchdog() {
    local ticket_id="$1" hb_file="$2" revert_state="$3" pipe_pid="$4"
    (
        while [[ -f "$hb_file" ]]; do
            sleep 60
            [[ ! -f "$hb_file" ]] && exit 0
            if ! kill -0 "$pipe_pid" 2>/dev/null; then
                printf "${YELLOW}[$(date '+%H:%M:%S')] ⚠  %s pipeline exited — reverting to '%s'${RESET}\n" \
                    "$ticket_id" "$revert_state"
                revert_ticket_status "$ticket_id" "$revert_state"
                rm -f "$hb_file"; exit 0
            fi
            local mtime age
            mtime=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$hb_file" 2>/dev/null) || exit 0
            age=$(( $(date +%s) - mtime ))
            if (( age > STALE_THRESHOLD )); then
                printf "${YELLOW}[$(date '+%H:%M:%S')] ⚠  %s silent %ds — reverting to '%s'${RESET}\n" \
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

start_status_watcher() {
    local ticket_id="$1" pipe_pid="$2" lock_dir="$3" hb_file="$4" allowed_states_str="$5"
    (
        while kill -0 "$pipe_pid" 2>/dev/null; do
            sleep 30
            [[ -z "${LINEAR_API_KEY:-}" ]] && continue
            local state
            state=$(get_ticket_state "$ticket_id" 2>/dev/null) || continue
            [[ -z "$state" ]] && continue
            local allowed=false s
            while IFS= read -r s; do
                [[ "$state" == "$s" ]] && allowed=true && break
            done < <(tr ':' '\n' <<< "$allowed_states_str")
            if ! $allowed; then
                log INFO "  $ticket_id advanced to '$state' — work complete, terminating pipeline"
                kill -- "-$(ps -o pgid= -p "$pipe_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null \
                    || kill "$pipe_pid" 2>/dev/null || true
                rm -f "$hb_file" 2>/dev/null || true
                rmdir "$lock_dir" 2>/dev/null || true
                exit 0
            fi
        done
    ) &
    STATUS_WATCHER_PID=$!
}

stop_status_watcher() {
    if [[ -n "${STATUS_WATCHER_PID:-}" ]]; then
        kill "$STATUS_WATCHER_PID" 2>/dev/null || true
        wait "$STATUS_WATCHER_PID" 2>/dev/null || true
        STATUS_WATCHER_PID=""
    fi
}

revert_stale_linear_claims() {
    local stuck_state="$1" revert_state="$2" lock_prefix="$3"
    [[ -z "${LINEAR_API_KEY:-}" ]] && return
    local response
    response=$(linear_gql "{ issues(filter:{team:{key:{eq:\"${LINEAR_TEAM_KEY}\"}},state:{name:{eq:\"${stuck_state}\"}}}) { nodes { identifier updatedAt } } }") || return
    local stale_tickets
    stale_tickets=$(python3 -c "
import json, sys, time
from datetime import datetime, timezone
stale = int(sys.argv[1])
data = json.loads(sys.stdin.read())
nodes = data.get('data', {}).get('issues', {}).get('nodes', [])
now = time.time()
for n in nodes:
    updated = n.get('updatedAt', '')
    if not updated:
        continue
    dt = datetime.fromisoformat(updated.replace('Z', '+00:00'))
    age = int(now - dt.timestamp())
    if age > stale:
        print(n['identifier'], age)
" "$LINEAR_STALE_THRESHOLD" <<< "$response" 2>/dev/null) || return
    [[ -z "$stale_tickets" ]] && return
    while IFS=' ' read -r ticket_id age; do
        [[ -z "$ticket_id" ]] && continue
        if [[ -d "/tmp/${lock_prefix}-lock-${ticket_id}" ]]; then
            log INFO "  $ticket_id in '${stuck_state}' — locally locked, active"
            continue
        fi
        log WARN "  $ticket_id stuck in '${stuck_state}' (${age}s) — reverting to '${revert_state}'"
        revert_ticket_status "$ticket_id" "$revert_state"
    done <<< "$stale_tickets"
}

# ── Ticket processor ──────────────────────────────────────────────────────────

PIPELINE_PID=""

process_ticket() {
    local ticket_id="$1"
    local log_file="$LOG_DIR/${ticket_id}-$(date '+%Y%m%d-%H%M%S').log"
    local exit_code=0

    local lock_dir="/tmp/research-pi-lock-${ticket_id}"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        log INFO "  $ticket_id is locked by another local agent — skipping"
        return
    fi

    local HB_FILE="/tmp/research-pi-heartbeat-${ticket_id}.txt"
    local REVERT_STATE="Plan Approved"
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local _cur_state
        _cur_state=$(get_ticket_state "$ticket_id") || _cur_state=""
        if [[ "$_cur_state" == "Todo" ]]; then
            REVERT_STATE="$_cur_state"
        fi
    fi
    echo "$REVERT_STATE" > "$HB_FILE"
    trap "rmdir '$lock_dir' 2>/dev/null || true; rm -f '${HB_FILE}'" RETURN

    divider "═" "Researching (pi): $ticket_id"
    log WORK "Ticket  : $ticket_id"
    log WORK "Log     : $log_file"
    log WORK "Started : $(date '+%Y-%m-%d %H:%M:%S')"
    divider
    echo ""

    start_heartbeat "$ticket_id" "$HB_FILE"

    # ── Pi invocation ─────────────────────────────────────────────────────────
    # --no-session : ephemeral, no session file written
    # --mode json  : stream events as JSON lines → parsed by PROCESSOR
    # Model comes from PI_DEFAULT_MODEL (set in entrypoint) or settings.json
    (
        pi \
            --no-session \
            --mode json \
            ${PI_DEFAULT_MODEL:+--model "$PI_DEFAULT_MODEL"} \
            "/ticket-research ${ticket_id}" \
            2>&1
    ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" "$HB_FILE" &
    PIPELINE_PID=$!

    start_stale_watchdog "$ticket_id" "$HB_FILE" "$REVERT_STATE" "$PIPELINE_PID"
    start_status_watcher "$ticket_id" "$PIPELINE_PID" "$lock_dir" "$HB_FILE" \
        "Todo:Research"

    wait "$PIPELINE_PID"
    exit_code=$?
    PIPELINE_PID=""

    stop_status_watcher
    stop_stale_watchdog
    rm -f "$HB_FILE"
    rmdir "$lock_dir" 2>/dev/null || true

    # Post-exit revert if ticket still stuck In Progress
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local final_state
        final_state=$(get_ticket_state "$ticket_id") || final_state=""
        if [[ "$final_state" == "In Progress" ]]; then
            log WARN "$ticket_id still 'In Progress' after exit — reverting to '$REVERT_STATE'"
            revert_ticket_status "$ticket_id" "$REVERT_STATE"
        fi
    fi

    stop_heartbeat

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log OK  "✓ Completed : $ticket_id  ($(date '+%H:%M:%S'))"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi

    if ticket_still_actionable "$ticket_id"; then
        log WARN "  $ticket_id still in Todo — will retry next poll"
    else
        echo "$ticket_id" >> "$PROCESSED_FILE"
        log INFO "  $ticket_id status advanced — cached"
    fi

    echo ""
    log INFO "Context cleared. Resuming poll loop..."
    divider
}

# ── Signal handling ───────────────────────────────────────────────────────────

SHUTTING_DOWN=false

on_interrupt() {
    $SHUTTING_DOWN && return
    SHUTTING_DOWN=true
    trap '' EXIT INT TERM
    echo ""
    log WARN "Interrupted — shutting down..."
    stop_heartbeat
    stop_status_watcher
    stop_stale_watchdog
    if [[ -n "$PIPELINE_PID" ]]; then
        kill -- "-$(ps -o pgid= -p "$PIPELINE_PID" 2>/dev/null | tr -d ' ')" 2>/dev/null \
            || kill "$PIPELINE_PID" 2>/dev/null || true
    fi
    pkill -P $$ -TERM 2>/dev/null || true
    sleep 0.3
    pkill -P $$ -KILL 2>/dev/null || true
    rm -f "$PROCESSOR"
    log INFO "Agent stopped (PID $$) — $(date '+%Y-%m-%d %H:%M:%S')"
    exit 130
}

on_exit() {
    stop_heartbeat
    rm -f "$PROCESSOR"
}

trap on_interrupt INT TERM
trap on_exit EXIT

interruptible_sleep() {
    sleep "$1" &
    wait $!
}

parse_ticket_ids() {
    echo "$1" | grep -oE "${LINEAR_TEAM_KEY}-[0-9]+" | sort -t- -k2 -n | uniq
}

is_processed()  { grep -qxF "$1" "$PROCESSED_FILE" 2>/dev/null; }

# ── Main loop ─────────────────────────────────────────────────────────────────

main() {
    divider "═"
    log INFO "  Autonomous Research Agent (pi)"
    log INFO "  Poll interval  : ${POLL_INTERVAL}s"
    log INFO "  Heartbeat      : ${HEARTBEAT_INTERVAL}s"
    log INFO "  Session logs   : $LOG_DIR/"
    log INFO "  Processed cache: $PROCESSED_FILE"
    divider "═"
    echo ""

    local cycle=0

    while true; do
        cycle=$((cycle + 1))
        revert_stale_linear_claims "Research" "Todo" "research-pi"
        log INFO "Poll #${cycle} — $(date '+%Y-%m-%d %H:%M:%S')"

        local raw; raw=$(fetch_pending_tickets)
        local ticket_ids; ticket_ids=$(parse_ticket_ids "$raw") || true

        if [[ -z "$ticket_ids" ]]; then
            log INFO "No pending tickets. Sleeping ${POLL_INTERVAL}s..."
            interruptible_sleep "$POLL_INTERVAL"
            continue
        fi

        local pending=()
        while IFS= read -r tid; do
            if is_processed "$tid"; then
                sed -i '' "/^${tid}$/d" "$PROCESSED_FILE" 2>/dev/null || true
                log INFO "  $tid re-entered polling state — evicted from cache, will reprocess"
            fi
            pending+=("$tid")
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
