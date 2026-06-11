#!/usr/bin/env bash
# autonomous-agent-slack-listen.sh
#
# Runs the Slack ticket intake bot: polls SLACK_TICKET_CHANNEL (falls back to
# SLACK_CHANNEL) for new messages, conducts a Claude-powered refinement
# conversation in thread, and creates a Linear ticket when the user approves.
#
# This is a long-running process — Docker restart policy keeps it alive.
#
# Required env (loaded from .env via docker-compose env_file):
#   SLACK_BOT_TOKEN          Slack bot token
#   SLACK_TICKET_CHANNEL     Channel to watch (falls back to SLACK_CHANNEL)
#   ANTHROPIC_API_KEY        Claude API key
#   LINEAR_API_KEY           Linear personal API key
#   LINEAR_TEAM_KEY          Linear team key e.g. GYL

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [slack-listen] $*"; }

log "Starting Slack ticket intake bot..."
exec node "$REPO_DIR/main.js" slack-listen
