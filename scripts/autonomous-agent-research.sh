#!/usr/bin/env bash
# autonomous-agent-research.sh
#
# Polls Linear for "Todo" tickets, then researches them one-by-one using
# /ticket-research. Shows live streaming output with real-time phase banners
# and a structured per-phase summary at the end of each ticket.
#
# Usage:
#   ./scripts/autonomous-agent-research.sh [--poll-interval <seconds>] [--once] [--reset]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load stage config
# shellcheck source=scripts/stages/research.env
source "$SCRIPT_DIR/stages/research.env"

# Set derived paths that depend on SCRIPT_DIR
LOG_DIR="$SCRIPT_DIR/autonomous-research-logs"
PROCESSED_FILE="/tmp/autonomous-research-processed.txt"

# Load shared library
# shellcheck source=scripts/lib/agent-core.sh
source "$SCRIPT_DIR/lib/agent-core.sh"

# ── Stage-specific: summary prompt ────────────────────────────────────────────

stage_build_summary_prompt() {
    local ticket_id="$1"
    cat << PROMPT_EOF
Below is the raw output from researching Linear ticket ${ticket_id} via /ticket-research.

Write a concise per-phase summary of what actually happened. Use ONLY phases that ran. Format each on its own line:

**Phase 1 — Fetch Ticket:** <ticket type, title>
**Phase 2 — Identify Research Areas:** <areas identified for investigation>
**Phase 3 — Parallel Codebase Exploration:** <sub-agents spawned, what each found>
**Phase 4 — Synthesize Research:** <key findings, files identified, complexity estimate>
**Phase 5 — Post Research & Transition:** <comment posted, status moved to Research Pending Approval>

Skip phases that did not run. Be factual. No filler.
PROMPT_EOF
}

# ── Stage-specific: completion log ───────────────────────────────────────────

stage_print_completion_log() {
    local ticket_id="$1"
    local exit_code="$2"
    if [[ $exit_code -eq 0 ]]; then
        log OK  "✓ Research complete : $ticket_id  ($(date '+%H:%M:%S'))"
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
    [[ "$state_name" == "Todo" ]]
}

# ── Stage-specific: post-exit revert ─────────────────────────────────────────
# No claim state: the ticket stays in 'Todo' while the agent works, so a crash
# needs no revert — it simply gets re-polled. No-op.

stage_post_exit_revert() {
    :
}

run_main_loop "$@"
