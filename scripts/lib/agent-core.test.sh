#!/usr/bin/env bash
# agent-core.test.sh — focused tests for the orphaned-lock reaper.
#
# Reproduces the livelock observed in production: a lock dir whose heartbeat
# file was removed (by the stale watchdog, an interrupt, or a crash) is
# invisible to the heartbeat-keyed reaper and blocks the stage forever with
# "locked by another local agent — skipping". The reaper must release any lock
# dir that has no live owner pipeline and no fresh heartbeat.
#
# Run: bash scripts/lib/agent-core.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Minimal env required to source the lib without tripping `set -u`.
STALE_THRESHOLD=1800
LINEAR_API_KEY=""            # makes revert_ticket_status a no-op (returns 1)
LINEAR_TEAM_KEY=""

# shellcheck source=scripts/lib/agent-core.sh
source "$SCRIPT_DIR/agent-core.sh"

# Silence the lib's logger during tests.
log() { :; }

PREFIX="testreap-$$"
PASS=0
FAIL=0

cleanup() {
    rm -rf /tmp/${PREFIX}-lock-* 2>/dev/null || true
    rm -f  /tmp/${PREFIX}-heartbeat-*.txt 2>/dev/null || true
    rm -f  /tmp/${PREFIX}-owner-*.pid 2>/dev/null || true
}
trap cleanup EXIT

assert() {
    local desc="$1"; shift
    if "$@"; then
        echo "  ✓ $desc"; PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"; FAIL=$((FAIL + 1))
    fi
}

mk_lock()  { mkdir -p "/tmp/${PREFIX}-lock-$1"; }
mk_hb()    { echo "${2:-Todo}" > "/tmp/${PREFIX}-heartbeat-$1.txt"; }
mk_owner() { echo "$2" > "/tmp/${PREFIX}-owner-$1.pid"; }
lock_exists() { [[ -d "/tmp/${PREFIX}-lock-$1" ]]; }
hb_exists()   { [[ -f "/tmp/${PREFIX}-heartbeat-$1.txt" ]]; }

# A PID that is guaranteed dead (no such process).
dead_pid() { echo 999999; }

echo "revert_stale_claims — orphaned lock reaper"

# 1. Orphaned lock dir, no heartbeat, no owner file (the production livelock).
cleanup
mk_lock GYL-100
revert_stale_claims "$PREFIX" "$PREFIX"
assert "releases a lock dir with no heartbeat and no owner" \
    bash -c "! [[ -d /tmp/${PREFIX}-lock-GYL-100 ]]"

# 2. Variant B: lock dir + fresh heartbeat, but owner pipeline is dead.
cleanup
mk_lock GYL-101
mk_hb   GYL-101
mk_owner GYL-101 "$(dead_pid)"
revert_stale_claims "$PREFIX" "$PREFIX"
assert "releases a lock whose owner pipeline is dead (even with fresh heartbeat)" \
    bash -c "! [[ -d /tmp/${PREFIX}-lock-GYL-101 ]]"

# 2b. Old-code orphan: lock dir + fresh heartbeat but NO owner file.
#     This is the exact shape of the locks already stuck in the running
#     containers (the pre-fix code never wrote an owner pid). No owner file
#     means owner_alive=false, so the lock must be released regardless of
#     heartbeat freshness.
cleanup
mk_lock GYL-104
mk_hb   GYL-104
revert_stale_claims "$PREFIX" "$PREFIX"
assert "releases a lock with a fresh heartbeat but no owner file (legacy orphan)" \
    bash -c "! [[ -d /tmp/${PREFIX}-lock-GYL-104 ]]"

# 3. Genuinely active: lock dir + fresh heartbeat + live owner → kept.
cleanup
mk_lock GYL-102
mk_hb   GYL-102
# Use a real, live background process as the owner.
sleep 30 & live_pid=$!
mk_owner GYL-102 "$live_pid"
revert_stale_claims "$PREFIX" "$PREFIX"
assert "keeps a lock with a live owner and fresh heartbeat" \
    bash -c "[[ -d /tmp/${PREFIX}-lock-GYL-102 ]]"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# 4. Stale heartbeat file with no lock dir → heartbeat removed (Pass 1).
cleanup
mk_hb GYL-103
# Backdate the heartbeat well past STALE_THRESHOLD.
touch -t 202001010000 "/tmp/${PREFIX}-heartbeat-GYL-103.txt"
revert_stale_claims "$PREFIX" "$PREFIX"
assert "removes a stale orphaned heartbeat file" \
    bash -c "! [[ -f /tmp/${PREFIX}-heartbeat-GYL-103.txt ]]"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
