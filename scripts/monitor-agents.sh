#!/usr/bin/env bash
# monitor-agents.sh — host-level health monitor for the autonomous agent fleet.
#
# A wedged agent container cannot watch itself, and the failures that take the
# fleet down (full disk, crashed/looping containers, silent livelocks) are only
# visible from the host Docker daemon. This script runs OUTSIDE the agents —
# either as the `monitor` sidecar service (mounts the Docker socket) or from a
# host cron — and alerts a human via scripts/notify-human.sh when something is
# wrong.
#
# Checks per cycle, for every agent container (autoframe-* / agent-*):
#   1. Disk      — root filesystem usage >= DISK_WARN_PCT (default 85%).
#   2. State     — container not running, or RestartCount climbing.
#   3. Liveness  — last log line older than 3x the poll interval (hung process).
#   4. Livelock  — "is locked by another local agent" seen but zero tickets
#                  "Started" in the recent window: claiming nothing despite work.
# Plus a host-level Docker disk check (reclaimable images / build cache).
#
# Alerts are DEDUPED via a small state file so a standing problem is reported
# once (and again when it RECOVERS), not every cycle — with a re-reminder every
# ALERT_REMIND_SECS. The script never auto-prunes; pruning is destructive and
# is left to a human (the alert includes the remediation command).
#
# Usage:
#   ./scripts/monitor-agents.sh            # poll loop (CHECK_INTERVAL secs)
#   ./scripts/monitor-agents.sh --once     # single pass, then exit
#   ./scripts/monitor-agents.sh --dry-run  # print alerts to stdout, don't notify
#
# Env knobs (all optional):
#   CHECK_INTERVAL=120   DISK_WARN_PCT=85   POLL_INTERVAL=60
#   LOG_WINDOW_MIN=15    ALERT_REMIND_SECS=21600   STATE_DIR=/var/lib/agent-monitor
#   CONTAINER_FILTER='autoframe-|agent-'

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/notify-human.sh"

CHECK_INTERVAL="${CHECK_INTERVAL:-120}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
LOG_WINDOW_MIN="${LOG_WINDOW_MIN:-15}"
ALERT_REMIND_SECS="${ALERT_REMIND_SECS:-21600}"   # 6h
STATE_DIR="${STATE_DIR:-/var/lib/agent-monitor}"
CONTAINER_FILTER="${CONTAINER_FILTER:-autoframe-|agent-}"
STATE_FILE="$STATE_DIR/state"

RUN_ONCE=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --once)    RUN_ONCE=true ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="/tmp/agent-monitor" && mkdir -p "$STATE_DIR" 2>/dev/null
STATE_FILE="$STATE_DIR/state"
touch "$STATE_FILE" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [monitor] $*"; }

# ── Alert dedup ───────────────────────────────────────────────────────────────
# State file lines: "<key>\t<status>\t<epoch_last_alerted>"
#   key    = container:check  (e.g. autoframe-retro-1:disk)
#   status = ok | bad

_state_get() { awk -F'\t' -v k="$1" '$1==k{print $2"\t"$3}' "$STATE_FILE" 2>/dev/null; }

_state_set() {
    local key="$1" status="$2" ts="$3" tmp
    tmp="$(mktemp 2>/dev/null)" || tmp="$STATE_FILE.tmp.$$"
    awk -F'\t' -v k="$key" '$1!=k' "$STATE_FILE" 2>/dev/null > "$tmp"
    printf '%s\t%s\t%s\n' "$key" "$status" "$ts" >> "$tmp"
    mv "$tmp" "$STATE_FILE" 2>/dev/null || true
}

notify() {
    local msg="$1"
    log "ALERT: $msg"
    $DRY_RUN && return
    [[ -x "$NOTIFIER" ]] && "$NOTIFIER" "$msg" >/dev/null 2>&1 || true
}

# Record a problem and alert only on OK->bad transition or after the remind
# interval. key uniquely identifies the (container, check) pair.
report_bad() {
    local key="$1" msg="$2" now prev_status prev_ts
    now=$(date +%s)
    IFS=$'\t' read -r prev_status prev_ts <<< "$(_state_get "$key")"
    prev_ts="${prev_ts:-0}"
    if [[ "$prev_status" != "bad" ]] || (( now - prev_ts >= ALERT_REMIND_SECS )); then
        notify "$msg"
        _state_set "$key" bad "$now"
    else
        _state_set "$key" bad "$prev_ts"
    fi
}

# Clear a problem; alert a recovery only if it was previously bad.
report_ok() {
    local key="$1" label="$2" now prev_status
    now=$(date +%s)
    IFS=$'\t' read -r prev_status _ <<< "$(_state_get "$key")"
    if [[ "$prev_status" == "bad" ]]; then
        notify "✅ RECOVERED: $label"
    fi
    _state_set "$key" ok "$now"
}

# ── Individual checks ─────────────────────────────────────────────────────────

agent_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -E "$CONTAINER_FILTER" || true
}

check_disk() {
    local c="$1" line use avail key="$1:disk"
    line=$(docker exec "$c" df -P / 2>/dev/null | awk 'NR==2')
    [[ -z "$line" ]] && return
    use=$(awk '{gsub(/%/,"",$5); print $5}' <<< "$line")
    avail=$(awk '{print $4}' <<< "$line")
    [[ "$use" =~ ^[0-9]+$ ]] || return
    if (( use >= DISK_WARN_PCT )); then
        report_bad "$key" "🛑 DISK on ${c}: root filesystem ${use}% full (${avail}KB free). Agents claim tickets via mkdir in /tmp — a full disk makes them silently report every ticket as \"locked\" and process nothing. Free space: \`docker builder prune -af && docker image prune -af\` then \`docker restart ${c}\`."
    else
        report_ok "$key" "DISK on ${c} back under ${DISK_WARN_PCT}% (now ${use}%)."
    fi
}

check_state() {
    local c="$1" running restarts key_run="$1:running" key_restart="$1:restart" prev
    read -r running restarts < <(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$c" 2>/dev/null)
    if [[ "$running" != "true" ]]; then
        report_bad "$key_run" "🛑 CONTAINER ${c} is not running (State.Running=${running:-unknown})."
        return
    else
        report_ok "$key_run" "CONTAINER ${c} is running again."
    fi
    # Restart-loop detection: compare RestartCount against last seen value.
    IFS=$'\t' read -r _ prev <<< "$(_state_get "$key_restart")"
    prev="${prev:-$restarts}"
    if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts > prev )); then
        report_bad "$key_restart" "⚠️ CONTAINER ${c} restarted ($((restarts - prev)) new restart(s); total ${restarts}). Possible crash loop."
    fi
    # Stash current count in the timestamp slot for next comparison.
    _state_set "$key_restart" ok "$restarts"
}

# True only for poll-loop stage agents (research/plan/implement/.../retro). Infra
# (redis) and event-driven services (slack-listen) don't poll, so liveness- and
# livelock-by-log checks would false-positive on them. We detect a poll agent by
# the "Poll #" heartbeat it prints every cycle.
is_poll_agent() {
    # NB: read into a var rather than `docker logs | grep -q`. grep -q exits on
    # first match and closes the pipe, killing `docker logs` with SIGPIPE; under
    # `set -o pipefail` that 141 would propagate and make this wrongly return
    # false, silently disabling the liveness/livelock checks.
    local out; out=$(docker logs --since 1h "$1" 2>&1)
    grep -q "Poll #" <<< "$out"
}

check_liveness() {
    local c="$1" last_ts last_epoch now age max key="$1:liveness"
    is_poll_agent "$c" || return
    last_ts=$(docker logs --tail 1 --timestamps "$c" 2>/dev/null | awk '{print $1}')
    [[ -z "$last_ts" ]] && return
    # docker --timestamps emits RFC3339 UTC (…Z). GNU date -d handles it directly;
    # the BSD/macOS fallback must be told the input is UTC (-u) or it assumes
    # local time and the age is off by the UTC offset.
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null) || \
        last_epoch=$(date -juf "%Y-%m-%dT%H:%M:%S" "${last_ts%.*}" +%s 2>/dev/null) || return
    now=$(date +%s); age=$(( now - last_epoch )); max=$(( POLL_INTERVAL * 3 ))
    if (( age > max )); then
        report_bad "$key" "⚠️ LIVENESS ${c}: no log output for ${age}s (> ${max}s). Poll loop may be hung."
    else
        report_ok "$key" "LIVENESS ${c} logging again."
    fi
}

check_livelock() {
    local c="$1" logs locked started key="$1:livelock"
    is_poll_agent "$c" || return
    logs=$(docker logs --since "${LOG_WINDOW_MIN}m" "$c" 2>&1)
    [[ -z "$logs" ]] && return
    locked=$(grep -c "is locked by another local agent" <<< "$logs")
    started=$(grep -cE "Started +:|CLAIM FAILED" <<< "$logs")
    # Claiming repeatedly but never starting a ticket = livelock (today's bug:
    # disk-full mkdir misreported as a lock). The hardened agent also emits
    # "CLAIM FAILED" which counts as activity and as its own strong signal.
    if (( locked > 0 && started == 0 )); then
        report_bad "$key" "🛑 LIVELOCK ${c}: ${locked} \"locked by another local agent\" message(s) in ${LOG_WINDOW_MIN}min but ZERO tickets started. The stage is claiming nothing despite actionable tickets — usually a full disk or orphaned-lock livelock. Check \`docker exec ${c} df -h /\`."
    else
        report_ok "$key" "LIVELOCK cleared on ${c} (tickets are being started again)."
    fi
    if grep -q "CLAIM FAILED" <<< "$logs"; then
        report_bad "$c:claimfail" "🛑 ${c} logged CLAIM FAILED — mkdir failed with no lock present (disk/FS error). The agent cannot claim any ticket."
    else
        report_ok "$c:claimfail" "CLAIM FAILED cleared on ${c}."
    fi
}

check_host_disk() {
    local key="host:docker-disk" recl
    # Reclaimable space across images + build cache, in human form for the alert.
    recl=$(docker system df 2>/dev/null | awk '
        /^Images/      {img=$NF}
        /^Build Cache/ {bc=$NF}
        END {if (img||bc) printf "images %s, build-cache %s reclaimable", img, bc}')
    # Only alert when a container disk check is already firing — host reclaimable
    # is advisory context, not an incident on its own.
    if [[ -n "$recl" ]] && grep -q $'\tbad\t' "$STATE_FILE" 2>/dev/null; then
        log "host docker reclaimable: $recl"
    fi
}

run_cycle() {
    local found=false c
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        found=true
        check_state    "$c"
        check_disk     "$c"
        check_liveness "$c"
        check_livelock "$c"
    done < <(agent_containers)
    $found || log "no agent containers matched /${CONTAINER_FILTER}/"
    check_host_disk
}

# ── Main ──────────────────────────────────────────────────────────────────────

if ! command -v docker >/dev/null 2>&1; then
    echo "docker CLI not found — monitor needs Docker access (mount the socket)." >&2
    exit 1
fi

log "agent monitor starting — interval ${CHECK_INTERVAL}s, disk warn ${DISK_WARN_PCT}%, filter /${CONTAINER_FILTER}/ (dry-run=${DRY_RUN})"

while true; do
    run_cycle
    $RUN_ONCE && break
    sleep "$CHECK_INTERVAL"
done
