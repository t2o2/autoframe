#!/usr/bin/env bash
# autonomous-agent-planning.sh
#
# Polls Linear for "Research Approved" tickets, then creates implementation plans for them
# one-by-one using /ticket-plan. Shows live streaming output with real-time
# phase banners and a structured per-phase summary at the end of each ticket.
#
# Usage:
#   ./scripts/autonomous-agent-planning.sh [--poll-interval <seconds>] [--once] [--reset]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load stage config
# shellcheck source=scripts/stages/plan.env
source "$SCRIPT_DIR/stages/plan.env"

# Set derived paths that depend on SCRIPT_DIR
LOG_DIR="$SCRIPT_DIR/autonomous-plan-logs"
PROCESSED_FILE="/tmp/autonomous-plan-processed.txt"

# Load shared library
# shellcheck source=scripts/lib/agent-core.sh
source "$SCRIPT_DIR/lib/agent-core.sh"

# ── Stage-specific: summary prompt ────────────────────────────────────────────

stage_build_summary_prompt() {
    local ticket_id="$1"
    cat << PROMPT_EOF
Below is the raw output from planning Linear ticket ${ticket_id} via /ticket-plan.

Write a concise per-phase summary of what actually happened. Use ONLY phases that ran. Format each on its own line:

**Phase 1 — Fetch Ticket & Research:** <ticket title, research comment found or absent>
**Phase 2 — Fill Research Gaps:** <sub-agents spawned, gaps filled>
**Phase 3 — Resolve Key Decisions:** <decisions made, any human judgment comments posted>
**Phase 4 — Write Implementation Plan:** <number of phases planned, key files identified, scope estimate>
**Phase 5 — Post Plan & Transition:** <comment posted, status moved to Plan Pending Approval>

Skip phases that did not run. Be factual. No filler.
PROMPT_EOF
}

# ── Stage-specific: completion log ───────────────────────────────────────────

stage_print_completion_log() {
    local ticket_id="$1"
    local exit_code="$2"
    if [[ $exit_code -eq 0 ]]; then
        log OK  "✓ Plan complete : $ticket_id  ($(date '+%H:%M:%S'))"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi
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
    [[ "$state_name" == "Research Approved" ]]
}

# ── Stage-specific: post-exit revert ─────────────────────────────────────────

stage_post_exit_revert() {
    local ticket_id="$1"
    local revert_state="$2"
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local final_state
        final_state=$(get_ticket_state "$ticket_id") || final_state=""
        if [[ "$final_state" == "Planning" ]]; then
            log WARN "$ticket_id still in 'Planning' after pipeline exit — reverting to 'Research Approved'"
            revert_ticket_status "$ticket_id" "Research Approved"
        fi
    fi
}

run_main_loop "$@"
