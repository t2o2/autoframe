#!/usr/bin/env bash
# autonomous-review-agent.sh
#
# Polls Linear for "In Review" tickets, then reviews them one-by-one using
# /ticket-review. Shows live streaming output with real-time phase banners
# and a structured per-phase summary at the end of each ticket.
#
# After /ticket-review completes:
#   PASS  → ticket moves to "Human Review"; script notifies you to verify
#   FAIL  → ticket moves to "Changes Required"; full findings logged
#
# Usage:
#   ./scripts/autonomous-review-agent.sh [--poll-interval <seconds>] [--once] [--reset]
#
# Flags:
#   --poll-interval <n>   Seconds between polls when idle (default: 60)
#   --once                Review one ticket and exit (useful for testing)
#   --reset               Clear the processed-tickets cache and start fresh

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/autonomous-review-logs"
PROCESSED_FILE="/tmp/autonomous-review-processed.txt"

# Load LINEAR_API_KEY from .env if not already set
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LINEAR_API_KEY:-}" && -f "$REPO_ROOT/.env" ]]; then
    LINEAR_API_KEY="$(grep -E '^LINEAR_API_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi

POLL_INTERVAL=60
HEARTBEAT_INTERVAL=30
TICKET_TIMEOUT=1800   # max seconds for a single ticket review (default 30 min)
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
# Detects Phase transitions, shows tool-call hints, and surfaces PASS/FAIL verdict.

PROCESSOR="/tmp/review-processor-$$.py"

cat > "$PROCESSOR" << 'PYEOF'
#!/usr/bin/env python3
"""
Reads Claude stream-json from stdin.
Prints formatted output with real-time Phase transition banners and surfaces
the PASS/FAIL verdict from /ticket-review output.
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
                elif name.startswith('mcp__linear'):
                    short = name.replace('mcp__linear-server__', '')
                    hint  = f'  {DM}{short}{R}'
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
        *)     color="$RESET"   ;;
    esac
    echo -e "${color}[$ts] [$level] $*${RESET}"
    echo "[$ts] [$level] $*" >> "$LOG_DIR/agent.log"
}

divider() {
    local char="${1:-─}"
    local label="${2:-}"
    if [[ -n "$label" ]]; then
        echo -e "${CYAN}${char}${char}${char} ${BOLD}${label}${RESET}${CYAN} $(printf '%*s' $((58 - ${#label})) '' | tr ' ' "$char")${RESET}"
    else
        echo -e "${CYAN}$(printf '%*s' 62 '' | tr ' ' "$char")${RESET}"
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
            printf "${DIM}[$(date '+%H:%M:%S')] ⏳  Still reviewing ${BOLD}%s${RESET}${DIM}... %dm%ds elapsed${RESET}\n" \
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
        "Below is the raw output from reviewing Linear ticket ${ticket_id} via /ticket-review.

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

---
$(cat)" \
    2>/dev/null \
    | while IFS= read -r line; do
        # Color PASS lines green, FAIL lines red
        if echo "$line" | grep -qiE "PASS|✅"; then
            echo -e "${GREEN}  ${line}${RESET}"
        elif echo "$line" | grep -qiE "FAIL|❌"; then
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

fetch_review_tickets() {
    log INFO "Querying Linear for 'In Review' tickets..."

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        log WARN "LINEAR_API_KEY not set — cannot query Linear"
        echo "NONE"
        return
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ issues(filter:{team:{key:{eq:\"GYL\"}},state:{name:{eq:\"In Review\"}}}) { nodes { identifier } } }"}' \
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
# Returns 0 (still In Review) or 1 (moved on to Human Review / Changes Required / etc.)

ticket_still_in_review() {
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

    [[ "$state_name" == "In Review" ]]
}

# ── Post-pass build check ─────────────────────────────────────────────────────
# Returns 0 (build ok or no Rust changes) or 1 (build failed).
# Runs cargo build --profile dev-fast --workspace from the ticket's worktree;
# falls back to creating a temporary worktree if the review one is gone.

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
        cargo build --profile dev-fast --workspace 2>&1
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

# ── Ticket reviewer ───────────────────────────────────────────────────────────

review_ticket() {
    local ticket_id="$1"
    local log_file="$LOG_DIR/${ticket_id}-$(date '+%Y%m%d-%H%M%S').log"
    local exit_code=0

    # ── Per-ticket lock (parallel-safe, macOS/Linux) ─────────────────────────
    local lock_dir="/tmp/review-lock-${ticket_id}"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        log INFO "  $ticket_id is locked by another local agent — skipping"
        return
    fi
    local HB_FILE="/tmp/review-heartbeat-${ticket_id}.txt"
    echo "In Review" > "$HB_FILE"
    # Release lock and heartbeat file on function exit (success, error, or return)
    trap "rmdir '$lock_dir' 2>/dev/null || true; rm -f '${HB_FILE}'" RETURN

    divider "═" "Reviewing: $ticket_id"
    log WORK "Ticket  : $ticket_id"
    log WORK "Log     : $log_file"
    log WORK "Started : $(date '+%Y-%m-%d %H:%M:%S')"
    divider
    echo ""

    start_heartbeat "$ticket_id"

    (
        claude --dangerously-skip-permissions \
               --no-session-persistence \
               -p "/ticket-review $ticket_id" \
               --output-format stream-json \
               --include-partial-messages \
               2>&1
    ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" "$HB_FILE" &
    PIPELINE_PID=$!

    start_stale_watchdog "$ticket_id" "$HB_FILE" "In Review" "$PIPELINE_PID"

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
        log OK "✓ Review session ended cleanly for $ticket_id  ($ended_at)"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi

    # ── Determine verdict from log ────────────────────────────────────────────
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

    # ── Post-pass build check ─────────────────────────────────────────────────
    # If the review passed but the branch has Rust changes, build the workspace
    # now to catch compile errors before the ticket reaches a human reviewer.
    if [[ "$verdict" == "PASS" ]]; then
        if ! run_build_check "$ticket_id" "$log_file"; then
            log ERROR "Build errors detected — overriding PASS to FAIL for $ticket_id"
            verdict="BUILD_FAIL"

            # Move Linear ticket back to Changes Required and leave a comment
            if [[ -n "${LINEAR_API_KEY:-}" ]]; then
                local changes_req_id
                changes_req_id=$(curl -sf \
                    -H "Authorization: ${LINEAR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d '{"query":"{ workflowStates(filter:{team:{key:{eq:\"GYL\"}},name:{eq:\"Changes Required\"}}) { nodes { id } } }"}' \
                    https://api.linear.app/graphql 2>/dev/null \
                    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['workflowStates']['nodes'][0]['id'])" 2>/dev/null || true)

                local ticket_gql_id
                ticket_gql_id=$(curl -sf \
                    -H "Authorization: ${LINEAR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d "{\"query\":\"{ issues(filter:{identifier:{eq:\\\"${ticket_id}\\\"}}) { nodes { id } } }\"}" \
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
            echo -e "${GREEN}${BOLD}  ║  Verify at http://localhost:8105 then /ticket-approve ║${RESET}"
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
            log WARN "Verdict unclear for $ticket_id — check log: $log_file"
            ;;
    esac

    # ── Per-phase summary ─────────────────────────────────────────────────────
    summarize_phases "$ticket_id" "$log_file"

    # ── Conditional cache: only skip on future polls if Linear status moved on ─
    if ticket_still_in_review "$ticket_id"; then
        log WARN "  $ticket_id still 'In Review' — will retry next poll (not cached)"
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
    log INFO "Review agent stopped (PID $$) — $(date '+%Y-%m-%d %H:%M:%S')"
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
    log INFO "  Autonomous Linear Review Agent"
    log INFO "  Watching status : In Review"
    log INFO "  Poll interval   : ${POLL_INTERVAL}s"
    log INFO "  Heartbeat       : ${HEARTBEAT_INTERVAL}s"
    log INFO "  Session logs    : $LOG_DIR/"
    log INFO "  Processed cache : $PROCESSED_FILE"
    divider "═"
    echo ""

    local cycle=0

    while true; do
        cycle=$((cycle + 1))
        revert_stale_claims "review" "review"
        log INFO "Poll #${cycle} — $(date '+%Y-%m-%d %H:%M:%S')"

        local raw; raw=$(fetch_review_tickets)
        local ticket_ids; ticket_ids=$(parse_ticket_ids "$raw") || true

        if [[ -z "$ticket_ids" ]]; then
            log INFO "No 'In Review' tickets. Sleeping ${POLL_INTERVAL}s..."
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
            log INFO "All 'In Review' tickets already processed this session. Sleeping ${POLL_INTERVAL}s..."
            interruptible_sleep "$POLL_INTERVAL"
            continue
        fi

        log INFO "Found ${#pending[@]} ticket(s) to review: ${pending[*]}"
        echo ""

        for ticket_id in "${pending[@]}"; do
            review_ticket "$ticket_id"
            echo ""
            if $RUN_ONCE; then
                log INFO "--once: stopping after first review"
                exit 0
            fi
        done

        log INFO "Cycle #${cycle} done. Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
