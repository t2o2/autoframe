#!/usr/bin/env bash
# autonomous-agent-retro.sh
#
# Polls Linear for "Retrospective" tickets, then runs a retrospective on each
# one-by-one using /ticket-retro. Shows live streaming output with real-time
# phase banners and a structured per-phase summary at the end of each ticket.
#
# After /ticket-retro completes, the ticket moves to Merge (handing off to
# the merge stage) and a structured retro comment + artifact file are written.
#
# Usage:
#   ./scripts/autonomous-agent-retro.sh [--poll-interval <seconds>] [--once] [--reset]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load stage config
# shellcheck source=scripts/stages/retro.env
source "$SCRIPT_DIR/stages/retro.env"

# Set derived paths that depend on SCRIPT_DIR
LOG_DIR="$SCRIPT_DIR/autonomous-retro-logs"
PROCESSED_FILE="/tmp/autonomous-retro-processed.txt"

# Load shared library
# shellcheck source=scripts/lib/agent-core.sh
source "$SCRIPT_DIR/lib/agent-core.sh"

# ── Stage-specific: summary prompt ────────────────────────────────────────────

stage_build_summary_prompt() {
    local ticket_id="$1"
    cat << PROMPT_EOF
Below is the raw output from running a retrospective on Linear ticket ${ticket_id} via /ticket-retro.

Write a concise per-phase summary of what actually happened. Use ONLY phases that ran. Format each line as:

**Phase N — [Name]:** <1-2 sentence conclusion>

Phases to cover if they ran:
- Phase 1 — Fetch & Claim: issue data retrieved, ticket claimed to Retrospective
- Phase 2 — Inspect Branch & Reconstruct Journey: branch diff/commits inspected, Changes Required cycles counted, timeline built
- Phase 3 — Extract Learnings: number of learnings produced, key themes identified
- Phase 4 — Post Retro & Write Artifact: comment posted to Linear, artifact written to thoughts/
- Phase 5 — Transition to Merge: ticket moved to Merge, hand-off comment posted

End with a one-line outcome: MERGING ✅ or INCOMPLETE ❌ with the key reason.
Be factual. No filler.
PROMPT_EOF
}

# ── Stage-specific: colorize retro summary (MERGING=green, INCOMPLETE=red, else magenta)

_colorize_summary_lines() {
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "MERGING|DONE|✅"; then
            echo -e "${GREEN}  ${line}${RESET}"
        elif echo "$line" | grep -qiE "INCOMPLETE|❌"; then
            echo -e "${RED}  ${line}${RESET}"
        else
            echo -e "${MAGENTA}  ${line}${RESET}"
        fi
    done
}

# ── Stage-specific: post-exit revert ─────────────────────────────────────────
# Retro is terminal-ish: if it exits with the ticket still in Retrospective,
# it simply gets retried next poll (same state — no revert).

stage_post_exit_revert() {
    local ticket_id="$1"
    local revert_state="$2"
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local final_state
        final_state=$(get_ticket_state "$ticket_id") || final_state=""
        if [[ "$final_state" == "Retrospective" ]]; then
            log WARN "$ticket_id still 'Retrospective' after exit — will retry next poll"
        fi
    fi
}

# ── Stage-specific: completion log ────────────────────────────────────────────

stage_print_completion_log() {
    local ticket_id="$1"
    local exit_code="$2"
    local ended_at; ended_at=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ $exit_code -eq 0 ]]; then
        log OK "✓ Retrospective session ended cleanly for $ticket_id  ($ended_at)"
    else
        log WARN "⚠  Exit code ${exit_code} for $ticket_id"
    fi
}

run_main_loop "$@"
