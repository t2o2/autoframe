#!/usr/bin/env bash
# autonomous-agent-slack-listen.sh
#
# Runs the Slack ticket intake bot: polls SLACK_TICKET_CHANNEL (falls back to
# SLACK_CHANNEL) for new messages, conducts a Claude-powered refinement
# conversation in thread, and creates a Linear ticket when the user approves.
#
# This is a long-running process — Docker restart policy keeps it alive.
#
# The user approves the drafted ticket with Approve/Cancel buttons (Block Kit),
# delivered over Socket Mode — no public interactivity Request URL needed.
#
# Required env (loaded from .env via docker-compose env_file):
#   SLACK_BOT_TOKEN          Slack bot token (xoxb-…)
#   SLACK_APP_TOKEN          Slack app-level token (xapp-…) — Socket Mode button clicks
#   SLACK_TICKET_CHANNEL     Channel to watch (falls back to SLACK_CHANNEL)
#   ANTHROPIC_API_KEY        Claude API key
#   LINEAR_API_KEY           Linear personal API key
#   LINEAR_TEAM_KEY          Linear team key e.g. GYL

set -uo pipefail

# The autoframe engine is baked into the image at /opt/autoframe, not in the
# cloned workspace repo (which belongs to the target project, not autoframe).
AUTOFRAME_DIR="/opt/autoframe"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [slack-listen] $*"; }

log "Starting Slack ticket intake bot..."
exec node "$AUTOFRAME_DIR/main.js" slack-listen
