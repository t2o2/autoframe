#!/usr/bin/env bash
# autonomous-agent-implement.sh
#
# Polls Linear for "Implementation" and "Changes Required" tickets, then
# implements them one-by-one using /ticket-implement. Shows live streaming output with
# real-time phase banners and a structured per-phase summary at the end of each ticket.
#
# Usage:
#   ./scripts/autonomous-agent-implement.sh [--poll-interval <seconds>] [--once] [--reset]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load stage config
# shellcheck source=scripts/stages/implement.env
source "$SCRIPT_DIR/stages/implement.env"

# Set derived paths that depend on SCRIPT_DIR
LOG_DIR="$SCRIPT_DIR/autonomous-implement-logs"
PROCESSED_FILE="/tmp/autonomous-implement-processed.txt"

# Load shared library
# shellcheck source=scripts/lib/agent-core.sh
source "$SCRIPT_DIR/lib/agent-core.sh"

# ── Stage-specific: dynamic REVERT_STATE ─────────────────────────────────────
# Read the actual current state so we record the right queue state (ticket may
# be "Implementation" or "Changes Required").

stage_compute_revert_state() {
    local ticket_id="$1"
    local fallback="Implementation"
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local _cur_state
        _cur_state=$(get_ticket_state "$ticket_id") || _cur_state=""
        if [[ "$_cur_state" == "Implementation" || "$_cur_state" == "Changes Required" ]]; then
            echo "$_cur_state"
            return
        fi
    fi
    echo "$fallback"
}

# ── Stage-specific: summary prompt ────────────────────────────────────────────

stage_build_summary_prompt() {
    local ticket_id="$1"
    cat << PROMPT_EOF
Below is the raw output from implementing Linear ticket ${ticket_id} through /ticket-implement.

Write a concise per-phase summary of what actually happened. Use ONLY phases that ran. Format each on its own line:

**Phase 0 — Worktree Setup:** <1 sentence>
**Phase 1 — Fetch & Analyze:** <ticket type, title, any dependencies or blockers found>
**Phase 2 — Plan Comment:** <assigned + plan comment posted>
**Phase 3 — Explore & Plan:** <root cause or design approach, key files identified>
**Phase 4 — Implement:** <what changed and why — be specific about files/functions>
**Phase 5a — Tests:** <suites run and pass/fail result>
**Phase 5b — Visual Proof:** <screenshots or API responses captured>
**Phase 6 — Commit & Push:** <branch pushed, Linear status updated to what>

Skip phases that did not run. Be factual. No filler.
PROMPT_EOF
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
    [[ "$state_name" == "Implementation" || "$state_name" == "Changes Required" ]]
}

# ── Stage-specific: post-exit revert ─────────────────────────────────────────
# No claim state: the ticket stays in its queue state ('Implementation'
# or 'Changes Required') while the agent works, so a crash needs no revert — it
# simply gets re-polled. No-op.

stage_post_exit_revert() {
    :
}

run_main_loop "$@"
