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

# Load LINEAR_API_KEY from .auto-claude/.env if not already set
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LINEAR_API_KEY:-}" && -f "$REPO_ROOT/.auto-claude/.env" ]]; then
    LINEAR_API_KEY="$(grep -E '^LINEAR_API_KEY=' "$REPO_ROOT/.auto-claude/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi

# Load LINEAR_TEAM_KEY from .auto-claude/.env if not already set
if [[ -z "${LINEAR_TEAM_KEY:-}" && -f "$REPO_ROOT/.auto-claude/.env" ]]; then
    LINEAR_TEAM_KEY="$(grep -E '^LINEAR_TEAM_KEY=' "$REPO_ROOT/.auto-claude/.env" | cut -d= -f2 | cut -d' ' -f1)"
fi
LINEAR_TEAM_KEY="${LINEAR_TEAM_KEY:-ENG}"  # fallback default

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
import sys, json, re

ticket_id = sys.argv[1] if len(sys.argv) > 1 else "TICKET-?"

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
        -d "{\"query\":\"{ issues(filter:{team:{key:{eq:\\\"${LINEAR_TEAM_KEY}\\\"}},state:{name:{eq:\\\"In Review\\\"}}}) { nodes { identifier } } }\"}" \
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
    echo "$1" | grep -oE '[A-Z]+-[0-9]+' | sort -t- -k2 -n | uniq
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
    trap "rmdir '$lock_dir' 2>/dev/null || true" RETURN

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
    ) | tee "$log_file" | python3 "$PROCESSOR" "$ticket_id" &
    PIPELINE_PID=$!

    # Watchdog kills the pipeline group after TICKET_TIMEOUT seconds
    ( sleep "$TICKET_TIMEOUT" && \
      kill -- "-$(ps -o pgid= -p "$PIPELINE_PID" 2>/dev/null | tr -d ' ')" 2>/dev/null ) &
    WATCHDOG_PID=$!

    wait "$PIPELINE_PID"
    exit_code=$?
    PIPELINE_PID=""
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true

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

    case "$verdict" in
        PASS)
            echo ""
            echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════╗${RESET}"
            echo -e "${GREEN}${BOLD}  ║  ✅  PASS — ticket moved to Human Review             ║${RESET}"
            echo -e "${GREEN}${BOLD}  ║  Verify the feature, then run /ticket-approve        ║${RESET}"
            echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════╝${RESET}"
            echo ""
            log PASS "Human verification required for $ticket_id — check Linear"
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
    log INFO "  Team key        : ${LINEAR_TEAM_KEY}"
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
                log INFO "  Skip (done this session): $tid"
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
