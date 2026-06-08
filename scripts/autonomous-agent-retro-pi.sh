#!/usr/bin/env bash
# autonomous-agent-retro-pi.sh
#
# Pi-native version of the retro agent.
# Polls Linear for "Retrospective" tickets, then runs a retrospective on each
# one-by-one using the /ticket-retro pi prompt template.
#
# Usage:
#   ./scripts/autonomous-agent-retro-pi.sh [--poll-interval <seconds>] [--once] [--reset]
#
# Flags:
#   --poll-interval <n>   Seconds between polls when idle (default: 60)
#   --once                Process one ticket and exit (useful for testing)
#   --reset               Clear the processed-tickets cache and start fresh

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/autonomous-retro-pi-logs"
PROCESSED_FILE="/tmp/autonomous-retro-pi-processed.txt"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTO_RULES="$SCRIPT_DIR/autonomous-process-rules.md"
if [[ -z "${LINEAR_API_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
    LINEAR_API_KEY="$(grep -E '^LINEAR_API_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi
if [[ -z "${LINEAR_TEAM_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
    LINEAR_TEAM_KEY="$(grep -E '^LINEAR_TEAM_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi

POLL_INTERVAL=60
HEARTBEAT_INTERVAL=30
MAX_CONTINUATIONS=3
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

PROCESSOR="/tmp/pi-retro-processor-$$.py"

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
DONE_RE  = re.compile(r'ticket-retro.*complete|retrospective complete|✅.*merging|handing off to merge|moved.*merging', re.IGNORECASE)

current_phase = ""
text_buffer = ""
done_seen = False

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

            while '\n' in text_buffer:
                line, text_buffer = text_buffer.split('\n', 1)
                m = PHASE_RE.search(line)
                if m:
                    new_phase = m.group(1).strip()
                    new_phase = re.sub(r'\s*[—–-]+\s*', ' — ', new_phase, count=1)
                    if new_phase != current_phase:
                        emit(f'\n{MG}{"━"*3} ▶ {BD}{new_phase}{R}{MG} {"━"*28}{R}')
                        current_phase = new_phase
                if not done_seen and DONE_RE.search(line):
                    done_seen = True
                    emit(f'\n{GN}{"█"*62}{R}')
                    emit(f'{GN}{BD}  ✅  RETROSPECTIVE COMPLETE — ticket moved to Merging{R}')
                    emit(f'{GN}{"█"*62}{R}\n')
                emit(f'{BL}[{ticket_id}]{R} {line}')

        elif ae_type == 'text_end':
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
            emit(f'{DM}[{ticket_id}] 🔍  {name}{hint}{R}')

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
        emit(f'{DM}[{ticket_id}] 🔍  {name}{hint}{R}')

    elif etype == 'agent_end':
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
        echo -e "${MAGENTA}${char}${char}${char} ${BOLD}${label}${RESET}${MAGENTA} $(printf '%*s' $((58 - ${#label})) '' | tr ' ' "$char")${RESET}"
    else
        echo -e "${MAGENTA}$(printf '%*s' 62 '' | tr ' ' "$char")${RESET}"
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
            printf "${DIM}[$(date '+%H:%M:%S')] ⏳  Still retrospecting ${BOLD}%s${RESET}${DIM}... %dm%ds elapsed${RESET}\n" \
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
    log INFO "Querying Linear for 'Retrospective' tickets..."

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        log WARN "LINEAR_API_KEY not set — cannot query Linear"
        echo "NONE"
        return
    fi

    local response
    response=$(linear_gql "{ issues(filter:{team:{key:{eq:\"${LINEAR_TEAM_KEY}\"}},state:{name:{in:[\"Retrospective\"]}}}) { nodes { identifier } } }")

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
    [[ "$state" == "Retrospective" ]]
}

# ── Stale-claim helpers ───────────────────────────────────────────────────────

STALE_THRESHOLD=1800
STALE_WATCHDOG_PID=""
STATUS_WATCHER_PID=""

start_stale_watchdog() {
    local ticket_id="$1" hb_file="$2" revert_state="$3" pipe_pid="$4"
    local lock_dir="${5:-}" owner_pid_file="${6:-}"
    # Release the whole claim — heartbeat, owner pid, AND the lock dir. Removing
    # only the heartbeat (the old behaviour) left an orphaned lock dir that no
    # reaper could see, livelocking the stage forever.
    release_claim() {
        rm -f "$hb_file"
        [[ -n "$owner_pid_file" ]] && rm -f "$owner_pid_file"
        if [[ -n "$lock_dir" ]]; then rmdir "$lock_dir" 2>/dev/null || true; fi
    }
    (
        while [[ -f "$hb_file" ]]; do
            sleep 60
            [[ ! -f "$hb_file" ]] && exit 0
            if ! kill -0 "$pipe_pid" 2>/dev/null; then
                printf "${YELLOW}[$(date '+%H:%M:%S')] ⚠  %s pipeline exited — reverting to '%s'${RESET}\n" \
                    "$ticket_id" "$revert_state"
                revert_ticket_status "$ticket_id" "$revert_state"
                release_claim; exit 0
            fi
            local mtime age
            mtime=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$hb_file" 2>/dev/null) || exit 0
            age=$(( $(date +%s) - mtime ))
            if (( age > STALE_THRESHOLD )); then
                printf "${YELLOW}[$(date '+%H:%M:%S')] ⚠  %s silent %ds — reverting to '%s'${RESET}\n" \
                    "$ticket_id" "$age" "$revert_state"
                revert_ticket_status "$ticket_id" "$revert_state"
                # Release BEFORE the group-kill: with job control off the kill may
                # also terminate this watchdog subshell, so do our cleanup first.
                release_claim
                kill_pipeline_tree "$pipe_pid"
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
    local owner_pid_file="${6:-}"
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
                # Release the claim BEFORE killing the pipeline (mirrors the
                # stale watchdog), then terminate the pipeline by its own
                # process group — never the agent's.
                rm -f "$hb_file" 2>/dev/null || true
                [[ -n "$owner_pid_file" ]] && rm -f "$owner_pid_file" 2>/dev/null || true
                rmdir "$lock_dir" 2>/dev/null || true
                kill_pipeline_tree "$pipe_pid"
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

# Reap orphaned local lock dirs. A lock dir left behind by the watchdog, an
# interrupt, or a crash blocks the stage forever: process_ticket reports
# "locked by another local agent — skipping" and nothing ever recovers it.
# Release any lock that lacks BOTH a live owner pipeline AND a fresh heartbeat
# (requiring both guards against PID reuse). Authoritative — keyed off the lock
# dir itself, not the heartbeat file which may already be gone.
revert_stale_local_claims() {
    local lock_prefix="$1"
    local lock_dir lock_tid owner_pid_file owner_pid lock_hb owner_alive hb_fresh mtime age revert_state
    for lock_dir in /tmp/${lock_prefix}-lock-*; do
        [[ -d "$lock_dir" ]] || continue
        lock_tid="${lock_dir##*/${lock_prefix}-lock-}"
        owner_pid_file="/tmp/${lock_prefix}-owner-${lock_tid}.pid"
        lock_hb="/tmp/${lock_prefix}-heartbeat-${lock_tid}.txt"
        owner_alive=false
        if [[ -f "$owner_pid_file" ]]; then
            owner_pid=$(cat "$owner_pid_file" 2>/dev/null) || owner_pid=""
            [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null && owner_alive=true
        fi
        hb_fresh=false
        if [[ -f "$lock_hb" ]]; then
            mtime=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$lock_hb" 2>/dev/null) || mtime=0
            age=$(( $(date +%s) - mtime ))
            (( age <= STALE_THRESHOLD )) && hb_fresh=true
        fi
        if $owner_alive && $hb_fresh; then continue; fi
        log WARN "  Orphaned lock released: $lock_tid (owner_alive=$owner_alive hb_fresh=$hb_fresh)"
        if [[ -f "$lock_hb" ]]; then
            revert_state=$(cat "$lock_hb" 2>/dev/null) || revert_state=""
            [[ -n "$revert_state" ]] && revert_ticket_status "$lock_tid" "$revert_state"
            rm -f "$lock_hb"
        fi
        rm -f "$owner_pid_file"
        rmdir "$lock_dir" 2>/dev/null || true
    done
}

# ── Ticket processor ──────────────────────────────────────────────────────────

PIPELINE_PID=""
# In-flight claim, so the interrupt/exit traps can release it. Set while a
# ticket is being processed; cleared by the RETURN trap.
CURRENT_LOCK_DIR=""
CURRENT_HB_FILE=""
CURRENT_OWNER_PID_FILE=""
# The agent's own process group, captured once at load. Job control is off, so
# without `set -m` a backgrounded pipeline shares this group — group-killing it
# would broadcast SIGTERM to the agent itself (PID 1 in the container) and tear
# down the whole poll loop. kill_pipeline_tree refuses to group-kill this group.
AGENT_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"

# Terminate a pipeline and its descendants WITHOUT ever broadcast-killing the
# agent. run_ticket launches the pipeline under `set -m`, so it has its OWN
# process group: group-kill it so claude's children (chromium, MCP servers,
# spawned shells) die too. If the pgid can't be resolved, is 1, or is the
# agent's own group (the legacy job-control-off case), a group kill would take
# down the agent — fall back to killing just the tracked subtree by PID.
kill_pipeline_tree() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" && "$pgid" != "1" && "$pgid" != "$AGENT_PGID" ]]; then
        kill -- "-$pgid" 2>/dev/null || true
    else
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    fi
}

process_ticket() {
    local ticket_id="$1"
    local exit_code=0

    local lock_dir="/tmp/retro-pi-lock-${ticket_id}"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        log INFO "  $ticket_id is locked by another local agent — skipping"
        return
    fi

    local HB_FILE="/tmp/retro-pi-heartbeat-${ticket_id}.txt"
    local owner_pid_file="/tmp/retro-pi-owner-${ticket_id}.pid"
    CURRENT_LOCK_DIR="$lock_dir"
    CURRENT_HB_FILE="$HB_FILE"
    CURRENT_OWNER_PID_FILE="$owner_pid_file"
    local REVERT_STATE="Retrospective"
    echo "$REVERT_STATE" > "$HB_FILE"
    trap "rmdir '$lock_dir' 2>/dev/null || true; rm -f '${HB_FILE}' '${owner_pid_file}'; CURRENT_LOCK_DIR=''; CURRENT_HB_FILE=''; CURRENT_OWNER_PID_FILE=''" RETURN

    local session_dir="$LOG_DIR/sessions/${ticket_id}"
    mkdir -p "$session_dir"

    divider "═" "Retrospective (pi): $ticket_id"
    log WORK "Ticket  : $ticket_id"
    log WORK "Session : $session_dir"
    log WORK "Started : $(date '+%Y-%m-%d %H:%M:%S')"
    divider
    echo ""

    local attempt=0

    while true; do
        attempt=$((attempt + 1))
        local log_file="$LOG_DIR/${ticket_id}-$(date '+%Y%m%d-%H%M%S').log"
        echo "$REVERT_STATE" > "$HB_FILE"

        start_heartbeat "$ticket_id" "$HB_FILE"

        # Launch the pipeline in its own process group (`set -m`) so the
        # watchdogs/interrupt can group-kill it without broadcasting to the agent.
        set -m
        if (( attempt == 1 )); then
            log INFO "Starting fresh session for $ticket_id"
            (
                pi \
                    --session-dir "$session_dir" \
                    --append-system-prompt "$AUTO_RULES" \
                    --mode json \
                    ${PI_DEFAULT_MODEL:+--model "$PI_DEFAULT_MODEL"} \
                    "/ticket-retro ${ticket_id}" \
                    2>&1
            ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" "$HB_FILE" &
        else
            local cur_state
            cur_state=$(get_ticket_state "$ticket_id" 2>/dev/null) || cur_state="unknown"
            log INFO "Continuing session for $ticket_id (attempt $attempt/$((MAX_CONTINUATIONS + 1)), state: $cur_state)"
            (
                pi \
                    --session-dir "$session_dir" \
                    --continue \
                    --append-system-prompt "$AUTO_RULES" \
                    --mode json \
                    ${PI_DEFAULT_MODEL:+--model "$PI_DEFAULT_MODEL"} \
                    "Your session ended but ticket ${ticket_id} is still in '${cur_state}' — it has NOT been completed. Background processes from your previous attempt are no longer running. Review what you have done so far and continue from where you left off. IMPORTANT: Do NOT use the process tool without alertOnSuccess: true — your session will end before background results arrive." \
                    2>&1
            ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" "$HB_FILE" &
        fi
        PIPELINE_PID=$!
        set +m
        echo "$PIPELINE_PID" > "$owner_pid_file"

        start_stale_watchdog "$ticket_id" "$HB_FILE" "$REVERT_STATE" "$PIPELINE_PID" \
            "$lock_dir" "$owner_pid_file"
        start_status_watcher "$ticket_id" "$PIPELINE_PID" "$lock_dir" "$HB_FILE" \
            "Retrospective" "$owner_pid_file"

        wait "$PIPELINE_PID"
        exit_code=$?
        PIPELINE_PID=""

        stop_status_watcher
        stop_stale_watchdog
        stop_heartbeat

        local final_state=""
        if [[ -n "${LINEAR_API_KEY:-}" ]]; then
            final_state=$(get_ticket_state "$ticket_id") || final_state=""
        fi

        if [[ -n "$final_state" && "$final_state" != "Retrospective" ]]; then
            log OK "✓ $ticket_id advanced to '$final_state' on attempt $attempt"
            break
        fi

        if (( attempt > MAX_CONTINUATIONS )); then
            log WARN "$ticket_id: exhausted $MAX_CONTINUATIONS continuation(s) — giving up"
            if [[ "$final_state" == "Retrospective" ]]; then
                log WARN "$ticket_id still 'Retrospective' — will retry next poll"
            fi
            break
        fi

        log INFO "$ticket_id still in '$final_state' after attempt $attempt — continuing session in 5s..."
        sleep 5
    done

    rm -f "$HB_FILE" "$owner_pid_file"
    rmdir "$lock_dir" 2>/dev/null || true

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log OK  "✓ Completed : $ticket_id  ($(date '+%H:%M:%S'))"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi

    if ticket_still_actionable "$ticket_id"; then
        log WARN "  $ticket_id still 'Retrospective' — will retry next poll"
        rm -rf "$session_dir"
    else
        echo "$ticket_id" >> "$PROCESSED_FILE"
        log INFO "  $ticket_id status advanced — cached"
        rm -rf "$session_dir"
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
        kill_pipeline_tree "$PIPELINE_PID"
    fi
    pkill -P $$ -TERM 2>/dev/null || true
    sleep 0.3
    pkill -P $$ -KILL 2>/dev/null || true
    # Release any in-flight claim so the next run isn't blocked by our own lock.
    [[ -n "$CURRENT_HB_FILE" ]] && rm -f "$CURRENT_HB_FILE" 2>/dev/null || true
    [[ -n "$CURRENT_OWNER_PID_FILE" ]] && rm -f "$CURRENT_OWNER_PID_FILE" 2>/dev/null || true
    [[ -n "$CURRENT_LOCK_DIR" ]] && rmdir "$CURRENT_LOCK_DIR" 2>/dev/null || true
    rm -f "$PROCESSOR"
    log INFO "Agent stopped (PID $$) — $(date '+%Y-%m-%d %H:%M:%S')"
    exit 130
}

on_exit() {
    stop_heartbeat
    [[ -n "$CURRENT_HB_FILE" ]] && rm -f "$CURRENT_HB_FILE" 2>/dev/null || true
    [[ -n "$CURRENT_OWNER_PID_FILE" ]] && rm -f "$CURRENT_OWNER_PID_FILE" 2>/dev/null || true
    [[ -n "$CURRENT_LOCK_DIR" ]] && rmdir "$CURRENT_LOCK_DIR" 2>/dev/null || true
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

is_processed() { grep -qxF "$1" "$PROCESSED_FILE" 2>/dev/null; }

# ── Main loop ─────────────────────────────────────────────────────────────────

main() {
    divider "═"
    log INFO "  Autonomous Retrospective Agent (pi)"
    log INFO "  Poll interval  : ${POLL_INTERVAL}s"
    log INFO "  Heartbeat      : ${HEARTBEAT_INTERVAL}s"
    log INFO "  Session logs   : $LOG_DIR/"
    log INFO "  Processed cache: $PROCESSED_FILE"
    divider "═"
    echo ""

    local cycle=0

    while true; do
        cycle=$((cycle + 1))
        revert_stale_local_claims "retro-pi"
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
