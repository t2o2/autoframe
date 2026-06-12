#!/usr/bin/env bash
# agent-core.sh — shared boilerplate for all autonomous Linear agent stages
#
# Source this file after setting stage-specific variables from a <stage>.env file.
# Then call run_main_loop "$@" to start the agent.
#
# Required env vars (set by stage .env before sourcing):
#   POLL_STATES_DISPLAY  — human-readable label for log messages
#   POLL_STATES_GQL      — GQL in-list value, e.g. \"Plan Approved\",\"Changes Required\"
#                          (with bash-level escaping for curl -d; bare quotes inside)
#   CLAIM_STATE          — state set when claiming a ticket
#   REVERT_STATE         — static fallback revert state
#   WATCH_STATES         — colon-separated allowed states for status-watcher
#   SLASH_COMMAND        — slash command to run, e.g. "/ticket-process"
#   LOCK_PREFIX          — prefix for lock dir and heartbeat file, e.g. "process"
#   STAGE_VERB           — gerund for heartbeat message ("processing", "reviewing", etc.)
#   STAGE_NAME           — title-case name for banners ("Processing", "Reviewing", etc.)
#   AGENT_DESCRIPTION    — one-line startup-banner description
#   LOG_DIR              — absolute path to log directory
#   PROCESSED_FILE       — absolute path to processed-tickets cache
#   TOOL_EMOJI           — emoji for tool-use lines ("🔧", "🔬", "📐")
#   DIVIDER_COLOR_VAR    — name of color variable to use for dividers ("BLUE", "CYAN", "GREEN")
#   STALE_THRESHOLD      — seconds of silence before reverting a stale claim
#
# Optional env vars:
#   LINEAR_STALE_THRESHOLD — if set: seconds before cross-container stale revert
#                            approve.sh does NOT set this; absence disables the check
#
# Optional hook functions (define in the stage script BEFORE calling run_main_loop):
#   stage_compute_revert_state <ticket_id>
#       — print the revert state; default echoes $REVERT_STATE
#         process.sh overrides this to read the current Linear state dynamically
#   stage_pre_poll_hook
#       — called at the start of each poll cycle; approve.sh uses this for prune_cache
#   stage_postprocess_ticket <ticket_id> <log_file> <exit_code>
#       — called after the pipeline completes; review.sh adds verdict+build-check,
#         approve.sh adds outcome detection; default is a no-op
#   stage_post_exit_revert <ticket_id> <revert_state>
#       — override the post-exit revert check; review.sh skips it entirely,
#         approve.sh checks Merging||In Progress; default checks CLAIM_STATE
#   stage_still_actionable <ticket_id>
#       — return 0 if ticket should be retried (not yet cached); default queries
#         Linear and checks if state matches any POLL_STATES (parsed from POLL_STATES_GQL)
#   write_stage_processor
#       — write the Python stream processor to $PROCESSOR; review.sh and approve.sh
#         override this with stage-specific regexes; default is the generic one
#   stage_build_summary_prompt <ticket_id>
#       — print the full claude prompt for phase summary; default is generic;
#         each stage overrides with the stage-specific phase list

# ── Defensive defaults (allow bash -n without variables set) ──────────────────
: "${POLL_STATES_DISPLAY:=tickets}"
: "${POLL_STATES_GQL:=}"
: "${CLAIM_STATE:=}"
: "${DONE_STATE:=}"
: "${REVERT_STATE:=}"
: "${PASS_STATE:=}"
: "${FAIL_STATE:=}"
: "${WATCH_STATES:=}"
: "${SLASH_COMMAND:=}"
: "${LOCK_PREFIX:=agent}"
: "${STAGE_VERB:=processing}"
: "${STAGE_NAME:=Processing}"
: "${AGENT_DESCRIPTION:=Autonomous Linear Agent}"
: "${TOOL_EMOJI:=🔧}"
: "${DIVIDER_COLOR_VAR:=BLUE}"
: "${STALE_THRESHOLD:=1800}"

# ── Load workflow contract from workflow.toml (if available) ─────────────────
# Locates workflow.toml by: $WORKFLOW_TOML → /workspace/repo/workflow.toml →
# bundled default at /opt/autoframe/workflow.toml (container) or repo root (dev).
# On success, exports WF_* variables for the current stage (keyed by LOCK_PREFIX).
# On failure, logs a warning and leaves the .env values in place (safe fallback).
_wf_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_wf_lib_dir}/workflow-loader.sh" ]]; then
    # shellcheck source=scripts/lib/workflow-loader.sh
    source "${_wf_lib_dir}/workflow-loader.sh"
fi
unset _wf_lib_dir

# Apply WF_* overrides: WF_* wins if non-empty, otherwise keep the .env value.
POLL_STATES_GQL="${WF_POLL_STATES_GQL:-$POLL_STATES_GQL}"
POLL_STATES_DISPLAY="${WF_POLL_STATES_DISPLAY:-$POLL_STATES_DISPLAY}"
CLAIM_STATE="${WF_CLAIM_STATE:-$CLAIM_STATE}"
DONE_STATE="${WF_DONE_STATE:-${DONE_STATE:-}}"
REVERT_STATE="${WF_REVERT_STATE:-$REVERT_STATE}"
PASS_STATE="${WF_PASS_STATE:-${PASS_STATE:-}}"
FAIL_STATE="${WF_FAIL_STATE:-${FAIL_STATE:-}}"
SLASH_COMMAND="${WF_SLASH_COMMAND:-$SLASH_COMMAND}"
LOCK_PREFIX="${WF_LOCK_PREFIX:-$LOCK_PREFIX}"
STAGE_VERB="${WF_STAGE_VERB:-$STAGE_VERB}"
WATCH_STATES="${WF_WATCH_STATES:-$WATCH_STATES}"
STALE_THRESHOLD="${WF_STALE_THRESHOLD:-$STALE_THRESHOLD}"
# LINEAR_STALE_THRESHOLD: only override if WF value is non-empty (approve intentionally unset)
if [[ -n "${WF_LINEAR_STALE_THRESHOLD:-}" ]]; then
    LINEAR_STALE_THRESHOLD="$WF_LINEAR_STALE_THRESHOLD"
fi
# WF_AGENT_PREAMBLE is exported for stage scripts to inject before slash commands
: "${WF_AGENT_PREAMBLE:=}"

# ── Runtime globals ───────────────────────────────────────────────────────────

HEARTBEAT_INTERVAL=30
POLL_INTERVAL=60
RUN_ONCE=false
RESET_CACHE=false
PIPELINE_PID=""
HEARTBEAT_PID=""
STALE_WATCHDOG_PID=""
STATUS_WATCHER_PID=""
SHUTTING_DOWN=false
PROCESSOR=""
# In-flight claim artifacts for the ticket currently in run_ticket. Tracked at
# script scope so on_interrupt can release the lock when a signal arrives
# mid-ticket — otherwise the lock dir outlives the process and livelocks the
# stage on restart ("locked by another local agent — skipping").
CURRENT_LOCK_DIR=""
CURRENT_HB_FILE=""
CURRENT_OWNER_PID_FILE=""
# The agent's own process group, captured once at load. Job control is off, so
# without `set -m` a backgrounded pipeline shares this group — group-killing it
# would broadcast SIGTERM to the agent itself (PID 1 in the container) and tear
# down the whole poll loop. kill_pipeline_tree refuses to group-kill this group.
AGENT_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

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
        PASS)  color="$GREEN"   ;;
        FAIL)  color="$RED"     ;;
        DONE)  color="$GREEN"   ;;
        *)     color="$RESET"   ;;
    esac
    echo -e "${color}[$ts] [$level] $*${RESET}"
    echo "[$ts] [$level] $*" >> "$LOG_DIR/agent.log"
}

divider() {
    local char="${1:-─}"
    local label="${2:-}"
    local dc; dc="${!DIVIDER_COLOR_VAR:-$BLUE}"
    if [[ -n "$label" ]]; then
        echo -e "${dc}${char}${char}${char} ${BOLD}${label}${RESET}${dc} $(printf '%*s' $((58 - ${#label})) '' | tr ' ' "$char")${RESET}"
    else
        echo -e "${dc}$(printf '%*s' 62 '' | tr ' ' "$char")${RESET}"
    fi
}

# ── Stream processor ──────────────────────────────────────────────────────────
# write_stage_processor writes $PROCESSOR.  Stages override this function to
# inject stage-specific Python (review: PASS/FAIL verdict; approve: merge result).

write_default_processor() {
    PROCESSOR="/tmp/${LOCK_PREFIX}-processor-$$.py"
    local emoji="$TOOL_EMOJI"
    cat > "$PROCESSOR" << PYEOF
#!/usr/bin/env python3
import sys, json, re, os

ticket_id      = sys.argv[1] if len(sys.argv) > 1 else "TICKET-?"
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
                elif name in ('Read', 'Edit', 'Write', 'Glob', 'Grep'):
                    path = inp.get('file_path') or inp.get('path') or inp.get('pattern') or ''
                    hint = f'  {DM}{path}{R}'
                emit(f'{DM}[{ticket_id}] ${emoji}  {name}{hint}{R}')

    elif etype == 'tool_use':
        name = event.get('name', '')
        if name:
            emit(f'{DM}[{ticket_id}] ${emoji}  {name}{R}')

    elif etype == 'result':
        if event.get('is_error'):
            err = str(event.get('result', 'unknown'))[:300]
            emit(f'{RD}[{ticket_id}] ❌  Error: {err}{R}')

    elif etype == 'system':
        if event.get('subtype') == 'init':
            emit(f'{DM}[{ticket_id}] Session started{R}')
PYEOF
}

write_stage_processor() {
    write_default_processor
}

# ── Heartbeat ─────────────────────────────────────────────────────────────────

start_heartbeat() {
    local ticket_id="$1"
    local hb_file="${2:-}"
    local verb="$STAGE_VERB"
    (
        local elapsed=0
        while true; do
            sleep "$HEARTBEAT_INTERVAL"
            elapsed=$((elapsed + HEARTBEAT_INTERVAL))
            [[ -n "$hb_file" && -f "$hb_file" ]] && touch "$hb_file"
            printf "${DIM}[$(date '+%H:%M:%S')] ⏳  Still ${verb} ${BOLD}%s${RESET}${DIM}... %dm%ds elapsed${RESET}\n" \
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

# stage_build_summary_prompt <ticket_id>
# Stages override this to return a stage-specific prompt.
stage_build_summary_prompt() {
    local ticket_id="$1"
    echo "Write a concise per-phase summary of what happened processing ticket ${ticket_id}. Be factual. No filler."
}

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

    local prompt_prefix
    prompt_prefix=$(stage_build_summary_prompt "$ticket_id")

    printf '%s' "$full_text" \
    | head -c 18000 \
    | claude --dangerously-skip-permissions --no-session-persistence -p \
        "${prompt_prefix}

---
$(cat)" \
    2>/dev/null \
    | _colorize_summary_lines \
    || log WARN "Summary generation failed"

    echo ""
    divider "═"
}

_colorize_summary_lines() {
    while IFS= read -r line; do
        echo -e "${GREEN}  ${line}${RESET}"
    done
}

# ── Interruptible sleep ───────────────────────────────────────────────────────

interruptible_sleep() {
    sleep "$1" &
    wait $!
}

# ── Linear helpers ────────────────────────────────────────────────────────────

get_ticket_state() {
    local ticket_id="$1"
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"
    [[ -z "${LINEAR_API_KEY:-}" ]] && echo "" && return
    curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${team_key}\\\"}},number:{eq:${issue_num}}}) { nodes { state { name } } } }\"}" \
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
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"
    local target_state="$2"
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1
    local issue_resp uuid states_resp state_id
    issue_resp=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${team_key}\\\"}},number:{eq:${issue_num}}}) { nodes { id } } }\"}" \
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
        -d "{\"query\":\"{ teams(filter:{key:{eq:\\\"${LINEAR_TEAM_KEY}\\\"}}) { nodes { states { nodes { id name } } } } }\"}" \
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

# ── Stale-claim watchdogs ─────────────────────────────────────────────────────

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

start_stale_watchdog() {
    local ticket_id="$1"
    local hb_file="$2"
    local revert_state="$3"
    local pipe_pid="$4"
    local lock_dir="${5:-}"
    local owner_pid_file="${6:-}"
    (
        # Release every claim artifact, never just the heartbeat. Removing the
        # heartbeat while leaving the lock dir is exactly what stranded the lock
        # and livelocked the stage.
        release_claim() {
            rm -f "$hb_file"
            [[ -n "$owner_pid_file" ]] && rm -f "$owner_pid_file"
            [[ -n "$lock_dir" ]] && rmdir "$lock_dir" 2>/dev/null || true
        }
        while [[ -f "$hb_file" ]]; do
            sleep 60
            [[ ! -f "$hb_file" ]] && exit 0
            if ! kill -0 "$pipe_pid" 2>/dev/null; then
                printf "${YELLOW}[$(date '+%H:%M:%S')] ⚠  %s pipeline exited — reverting to '%s'${RESET}\n" \
                    "$ticket_id" "$revert_state"
                revert_ticket_status "$ticket_id" "$revert_state"
                release_claim
                exit 0
            fi
            local mtime age
            mtime=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$hb_file" 2>/dev/null) || exit 0
            age=$(( $(date +%s) - mtime ))
            if (( age > STALE_THRESHOLD )); then
                printf "${YELLOW}[$(date '+%H:%M:%S')] ⚠  %s silent %ds (process alive) — reverting to '%s'${RESET}\n" \
                    "$ticket_id" "$age" "$revert_state"
                revert_ticket_status "$ticket_id" "$revert_state"
                # Release the claim BEFORE killing the pipeline, then terminate
                # the pipeline by its own process group (never the agent's).
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
    local ticket_id="$1"
    local pipe_pid="$2"
    local lock_dir="$3"
    local hb_file="$4"
    local allowed_states_str="$5"
    (
        while kill -0 "$pipe_pid" 2>/dev/null; do
            sleep 30
            [[ -z "${LINEAR_API_KEY:-}" ]] && continue
            local state
            state=$(get_ticket_state "$ticket_id" 2>/dev/null) || continue
            [[ -z "$state" ]] && continue
            local allowed=false
            local s
            while IFS= read -r s; do
                [[ "$state" == "$s" ]] && allowed=true && break
            done < <(tr ':' '\n' <<< "$allowed_states_str")
            if ! $allowed; then
                log INFO "  $ticket_id advanced to '$state' — work complete, terminating pipeline"
                # Release the claim BEFORE killing the pipeline (mirrors the
                # stale watchdog), then terminate the pipeline by its own
                # process group — never the agent's.
                rm -f "$hb_file" 2>/dev/null || true
                rm -f "/tmp/${LOCK_PREFIX}-owner-${ticket_id}.pid" 2>/dev/null || true
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

# Revert stale heartbeat files left by crashed agent instances.
revert_stale_claims() {
    local hb_prefix="$1"
    local lock_prefix="$2"
    local stale_secs="$STALE_THRESHOLD"
    local hb ticket_id revert_state mtime age
    for hb in /tmp/${hb_prefix}-heartbeat-*.txt; do
        [[ -f "$hb" ]] || continue
        ticket_id=$(basename "$hb" .txt | sed "s/${hb_prefix}-heartbeat-//")
        revert_state=$(cat "$hb" 2>/dev/null) || continue
        mtime=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$hb" 2>/dev/null) || continue
        age=$(( $(date +%s) - mtime ))
        if (( age > stale_secs )); then
            log WARN "Stale claim: $ticket_id (${age}s old, revert→'$revert_state')"
            revert_ticket_status "$ticket_id" "$revert_state"
            rm -f "$hb"
            rm -f "/tmp/${lock_prefix}-owner-${ticket_id}.pid"
            rmdir "/tmp/${lock_prefix}-lock-${ticket_id}" 2>/dev/null || true
        else
            log INFO "Active claim file found: $ticket_id (${age}s, within threshold)"
        fi
    done

    # Pass 2 — authoritative orphaned lock-dir sweep.
    #
    # Pass 1 above only sees tickets that still have a heartbeat file. A lock dir
    # whose heartbeat was removed (by the stale watchdog, an interrupt, or a
    # crash) is invisible to it and blocks the stage forever with
    # "locked by another local agent — skipping". This is the production
    # livelock. Because run_ticket is synchronous, no pipeline is ever running
    # when this reaper executes (top of the poll loop, between tickets), so any
    # lock dir present is by definition an orphan. We still verify liveness
    # defensively: release every lock that lacks BOTH a live owner pipeline and
    # a fresh heartbeat. Requiring both guards against PID reuse (a recycled
    # owner PID alone, with a stale heartbeat, is still reaped).
    local lock_dir lock_tid owner_pid_file owner_pid lock_hb owner_alive hb_fresh
    for lock_dir in /tmp/${lock_prefix}-lock-*; do
        [[ -d "$lock_dir" ]] || continue
        lock_tid="${lock_dir##*/${lock_prefix}-lock-}"
        owner_pid_file="/tmp/${lock_prefix}-owner-${lock_tid}.pid"
        lock_hb="/tmp/${hb_prefix}-heartbeat-${lock_tid}.txt"

        owner_alive=false
        if [[ -f "$owner_pid_file" ]]; then
            owner_pid=$(cat "$owner_pid_file" 2>/dev/null) || owner_pid=""
            [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null && owner_alive=true
        fi

        hb_fresh=false
        if [[ -f "$lock_hb" ]]; then
            mtime=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$lock_hb" 2>/dev/null) || mtime=0
            age=$(( $(date +%s) - mtime ))
            (( age <= stale_secs )) && hb_fresh=true
        fi

        if $owner_alive && $hb_fresh; then
            continue
        fi

        log WARN "Orphaned lock released: $lock_tid (owner_alive=$owner_alive hb_fresh=$hb_fresh)"
        if [[ -f "$lock_hb" ]]; then
            revert_state=$(cat "$lock_hb" 2>/dev/null) || revert_state=""
            [[ -n "$revert_state" ]] && revert_ticket_status "$lock_tid" "$revert_state"
            rm -f "$lock_hb"
        fi
        rm -f "$owner_pid_file"
        rmdir "$lock_dir" 2>/dev/null || true
    done
}

# Revert tickets stuck in an intermediate Linear state across container boundaries.
# Only called when LINEAR_STALE_THRESHOLD is set (approve.sh does not set it).
revert_stale_linear_claims() {
    local stuck_state="$1"
    local revert_state="$2"
    local lock_prefix="$3"
    [[ -z "${LINEAR_API_KEY:-}" ]] && return
    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${LINEAR_TEAM_KEY}\\\"}},state:{name:{eq:\\\"${stuck_state}\\\"}}}){ nodes { identifier updatedAt } } }\"}" \
        https://api.linear.app/graphql 2>/dev/null) || return
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
        log WARN "  $ticket_id stuck in '${stuck_state}' (${age}s since last update) — reverting to '${revert_state}'"
        revert_ticket_status "$ticket_id" "$revert_state"
    done <<< "$stale_tickets"
}

# ── Linear fetch ──────────────────────────────────────────────────────────────

fetch_pending_tickets() {
    log INFO "Querying Linear for ${POLL_STATES_DISPLAY} tickets..."

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        log WARN "LINEAR_API_KEY not set — cannot query Linear"
        echo "NONE"
        return
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${LINEAR_TEAM_KEY}\\\"}},state:{name:{in:[${POLL_STATES_GQL}]}}}) { nodes { identifier priority createdAt } } }\"}" \
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
# priority sort: 0 (no priority) sinks to rank 5; 1=urgent … 4=low come first
# secondary: createdAt ascending (oldest first)
def prio_rank(n):
    p = n.get('priority') or 0  # missing OR null → 0 (no priority)
    return (5 if p == 0 else p, n.get('createdAt') or '')
nodes.sort(key=prio_rank)
ids = [n['identifier'] for n in nodes]
print('\n'.join(ids) if ids else 'NONE')
" <<< "$response")

    log INFO "fetch result: $result"
    echo "$result"
}

# parse_ticket_ids: extract <TEAM_KEY>-<N> identifiers from a newline-separated list,
# preserving the priority-sorted order from fetch_pending_tickets.
parse_ticket_ids() {
    echo "$1" | grep -oE "${LINEAR_TEAM_KEY}-[0-9]+" | awk '!seen[$0]++'
}

is_processed()   { grep -qxF "$1" "$PROCESSED_FILE" 2>/dev/null; }
mark_processed() { echo "$1" >> "$PROCESSED_FILE"; }

# ── Default hook implementations ──────────────────────────────────────────────

# Default: static REVERT_STATE.  process.sh overrides to read current Linear state.
stage_compute_revert_state() {
    echo "$REVERT_STATE"
}

# Default: no-op.  approve.sh overrides with prune_cache.
stage_pre_poll_hook() {
    :
}

# Default: no-op.  review.sh and approve.sh override with verdict/outcome logic.
# Called AFTER stop_heartbeat, BEFORE summarize_phases.
stage_postprocess_ticket() {
    :
}

# Default: print the completion status line.
# review.sh and approve.sh override this to print their stage-specific wording.
stage_print_completion_log() {
    local ticket_id="$1"
    local exit_code="$2"
    if [[ $exit_code -eq 0 ]]; then
        log OK  "✓ Completed : $ticket_id  ($(date '+%H:%M:%S'))"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi
}

# Default: no-op.  approve.sh overrides with git rebase/merge/cherry-pick --abort.
# Called after rm HB_FILE, before stage_post_exit_revert.
stage_pre_revert_cleanup() {
    :
}

# Default: revert if ticket is still in CLAIM_STATE after pipeline exits.
# review.sh overrides to skip entirely; approve.sh overrides to check two states.
stage_post_exit_revert() {
    local ticket_id="$1"
    local revert_state="$2"
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local final_state
        final_state=$(get_ticket_state "$ticket_id") || final_state=""
        if [[ "$final_state" == "$CLAIM_STATE" ]]; then
            log WARN "$ticket_id still '$CLAIM_STATE' after pipeline exit — reverting to '$revert_state'"
            revert_ticket_status "$ticket_id" "$revert_state"
        fi
    fi
}

# Default: query Linear and check if current state matches any POLL_STATES.
# Extracts bare state names by stripping GQL-escaped quotes from POLL_STATES_GQL.
stage_still_actionable() {
    local ticket_id="$1"
    local team_key="${ticket_id%-*}" issue_num="${ticket_id#*-}"

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        return 1
    fi

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

    # Parse bare state names from POLL_STATES_GQL (strip \" escapes and commas).
    # POLL_STATES_GQL holds backslash-escaped quotes (\"Plan Approved\",...), so the
    # sed pattern \\" matches one literal backslash + quote — strip both per name.
    local poll_states_bare
    poll_states_bare=$(echo "$POLL_STATES_GQL" | tr ',' '\n' | sed 's/\\"//g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    local s
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        [[ "$state_name" == "$s" ]] && return 0
    done <<< "$poll_states_bare"
    return 1
}

# Default: generic summary prompt prefix (the part before "---\n<content>").
# Each stage overrides with its stage-specific intro + phase list.
# DO NOT include "---\n$(cat)" — summarize_phases appends that automatically.
stage_build_summary_prompt() {
    local ticket_id="$1"
    echo "Write a concise per-phase summary of what happened processing ticket ${ticket_id}. Be factual. No filler."
}

# ── Per-ticket driver ─────────────────────────────────────────────────────────

run_ticket() {
    local ticket_id="$1"
    local log_file="$LOG_DIR/${ticket_id}-$(date '+%Y%m%d-%H%M%S').log"
    local exit_code=0

    local lock_dir="/tmp/${LOCK_PREFIX}-lock-${ticket_id}"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        log INFO "  $ticket_id is locked by another local agent — skipping"
        return
    fi

    local HB_FILE="/tmp/${LOCK_PREFIX}-heartbeat-${ticket_id}.txt"
    local owner_pid_file="/tmp/${LOCK_PREFIX}-owner-${ticket_id}.pid"
    local revert_state
    revert_state=$(stage_compute_revert_state "$ticket_id")
    echo "$revert_state" > "$HB_FILE"
    # Expose the in-flight artifacts so on_interrupt can release them on a signal.
    CURRENT_LOCK_DIR="$lock_dir"
    CURRENT_HB_FILE="$HB_FILE"
    CURRENT_OWNER_PID_FILE="$owner_pid_file"
    trap "rmdir '$lock_dir' 2>/dev/null || true; rm -f '${HB_FILE}' '${owner_pid_file}'; CURRENT_LOCK_DIR=''; CURRENT_HB_FILE=''; CURRENT_OWNER_PID_FILE=''" RETURN

    divider "═" "${STAGE_NAME}: $ticket_id"
    log WORK "Ticket  : $ticket_id"
    log WORK "Log     : $log_file"
    log WORK "Started : $(date '+%Y-%m-%d %H:%M:%S')"
    divider
    echo ""

    start_heartbeat "$ticket_id" "$HB_FILE"

    # Launch the pipeline in its OWN process group (`set -m`) so the watchdogs
    # and on_interrupt can terminate claude and all its children with a targeted
    # group kill, instead of broadcasting SIGTERM to the agent's own group.
    set -m
    (
        claude --dangerously-skip-permissions \
               --no-session-persistence \
               -p "${SLASH_COMMAND} ${ticket_id}" \
               --output-format stream-json \
               --include-partial-messages \
               2>&1
    ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" "$HB_FILE" &
    PIPELINE_PID=$!
    set +m
    # Record the pipeline PID so the reaper can detect a dead owner and release
    # an orphaned lock even when a stale heartbeat file makes it look "active".
    echo "$PIPELINE_PID" > "$owner_pid_file"

    start_stale_watchdog "$ticket_id" "$HB_FILE" "$revert_state" "$PIPELINE_PID" "$lock_dir" "$owner_pid_file"
    start_status_watcher "$ticket_id" "$PIPELINE_PID" "$lock_dir" "$HB_FILE" "$WATCH_STATES"

    wait "$PIPELINE_PID"
    exit_code=$?
    PIPELINE_PID=""

    stop_status_watcher
    stop_stale_watchdog
    rm -f "$HB_FILE" "$owner_pid_file"
    rmdir "$lock_dir" 2>/dev/null || true

    stage_pre_revert_cleanup "$ticket_id"

    stage_post_exit_revert "$ticket_id" "$revert_state"

    stop_heartbeat

    echo ""
    stage_print_completion_log "$ticket_id" "$exit_code"

    stage_postprocess_ticket "$ticket_id" "$log_file" "$exit_code"

    summarize_phases "$ticket_id" "$log_file"

    if stage_still_actionable "$ticket_id"; then
        log WARN "  $ticket_id still actionable — will retry next poll (not cached)"
    else
        mark_processed "$ticket_id"
        log INFO "  $ticket_id status advanced — cached to skip future polls"
    fi

    echo ""
    log INFO "Context cleared. Resuming poll loop..."
    divider
}

# ── Signal handling ───────────────────────────────────────────────────────────

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
    # Release the in-flight ticket's claim so a restart doesn't find an orphaned
    # lock dir and livelock on "locked by another local agent — skipping".
    [[ -n "$CURRENT_HB_FILE" ]]        && rm -f "$CURRENT_HB_FILE"
    [[ -n "$CURRENT_OWNER_PID_FILE" ]] && rm -f "$CURRENT_OWNER_PID_FILE"
    [[ -n "$CURRENT_LOCK_DIR" ]]       && rmdir "$CURRENT_LOCK_DIR" 2>/dev/null || true
    rm -f "$PROCESSOR"
    log INFO "${STAGE_NAME} agent stopped (PID $$) — $(date '+%Y-%m-%d %H:%M:%S')"
    log INFO "Session log : $LOG_DIR/agent.log"
    exit 130
}

on_exit() {
    stop_heartbeat
    [[ -n "$CURRENT_HB_FILE" ]]        && rm -f "$CURRENT_HB_FILE"
    [[ -n "$CURRENT_OWNER_PID_FILE" ]] && rm -f "$CURRENT_OWNER_PID_FILE"
    [[ -n "$CURRENT_LOCK_DIR" ]]       && rmdir "$CURRENT_LOCK_DIR" 2>/dev/null || true
    rm -f "$PROCESSOR"
}

# ── CLI argument parsing ──────────────────────────────────────────────────────

_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
            --once)          RUN_ONCE=true;       shift   ;;
            --reset)         RESET_CACHE=true;    shift   ;;
            *) echo "Unknown flag: $1"; exit 1 ;;
        esac
    done
}

# ── Main poll loop ────────────────────────────────────────────────────────────
# Call this from the stage script: run_main_loop "$@"
# BASH_SOURCE[1] is the calling script (stage .sh), used to locate the repo root.

run_main_loop() {
    _parse_args "$@"

    local calling_script="${BASH_SOURCE[1]}"
    local script_dir; script_dir="$(cd "$(dirname "$calling_script")" && pwd)"
    REPO_ROOT="$(cd "$script_dir/.." && pwd)"

    if [[ -z "${LINEAR_API_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
        LINEAR_API_KEY="$(grep -E '^LINEAR_API_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
    fi
    if [[ -z "${LINEAR_TEAM_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
        LINEAR_TEAM_KEY="$(grep -E '^LINEAR_TEAM_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
    fi

    mkdir -p "$LOG_DIR"
    if $RESET_CACHE; then > "$PROCESSED_FILE"; echo "Cache cleared."; fi
    touch "$PROCESSED_FILE"

    write_stage_processor

    trap on_interrupt INT TERM
    trap on_exit EXIT

    divider "═"
    log INFO "  ${AGENT_DESCRIPTION}"
    log INFO "  Poll interval  : ${POLL_INTERVAL}s"
    log INFO "  Heartbeat      : ${HEARTBEAT_INTERVAL}s"
    log INFO "  Session logs   : $LOG_DIR/"
    log INFO "  Processed cache: $PROCESSED_FILE"
    divider "═"
    echo ""

    local cycle=0

    while true; do
        cycle=$((cycle + 1))
        revert_stale_claims "$LOCK_PREFIX" "$LOCK_PREFIX"
        if [[ -n "${LINEAR_STALE_THRESHOLD:-}" && -n "${CLAIM_STATE:-}" ]]; then
            revert_stale_linear_claims "$CLAIM_STATE" "$REVERT_STATE" "$LOCK_PREFIX"
        fi
        log INFO "Poll #${cycle} — $(date '+%Y-%m-%d %H:%M:%S')"
        stage_pre_poll_hook

        local raw; raw=$(fetch_pending_tickets)
        local ticket_ids; ticket_ids=$(parse_ticket_ids "$raw") || true

        if [[ -z "$ticket_ids" ]]; then
            log INFO "No ${POLL_STATES_DISPLAY} tickets. Sleeping ${POLL_INTERVAL}s..."
            interruptible_sleep "$POLL_INTERVAL"
            continue
        fi

        local pending=()
        while IFS= read -r tid; do
            if is_processed "$tid"; then
                sed -i.bak "/^${tid}$/d" "$PROCESSED_FILE" 2>/dev/null && rm -f "${PROCESSED_FILE}.bak" 2>/dev/null; true
                log INFO "  $tid re-entered polling state — evicted from cache, will reprocess"
                pending+=("$tid")
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
            run_ticket "$ticket_id"
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
