#!/usr/bin/env bash
# notify-human.sh — fire-and-forget one-way notification to the feedback channel.
#
# Unlike ask-human.sh this never waits for a reply; it just posts a message.
# Channel-agnostic: Slack (preferred) when SLACK_BOT_TOKEN + SLACK_CHANNEL are
# set, else Telegram when TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID are set.
# Best-effort: always exits 0 so a notification failure never breaks a caller.
#
# Usage:
#   ./scripts/notify-human.sh "<message>"            # plain text (Slack mrkdwn / Telegram Markdown)
#   echo "<message>" | ./scripts/notify-human.sh     # message on stdin

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/.env"

read_env() {
    local k="$1" v="${!1:-}"
    if [[ -z "$v" && -f "$ENV_FILE" ]]; then
        v="$(grep -E "^${k}=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
    fi
    echo "$v"
}

MSG="${1:-}"
[[ -z "$MSG" && ! -t 0 ]] && MSG="$(cat)"
[[ -z "$MSG" ]] && exit 0

SLACK_BOT_TOKEN="$(read_env SLACK_BOT_TOKEN)"
SLACK_CHANNEL="$(read_env SLACK_CHANNEL)"
TELEGRAM_BOT_TOKEN="$(read_env TELEGRAM_BOT_TOKEN)"
TELEGRAM_CHAT_ID="$(read_env TELEGRAM_CHAT_ID)"

_CHANNEL="${HUMAN_FEEDBACK_CHANNEL:-}"
if [[ -z "$_CHANNEL" ]]; then
    [[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_CHANNEL" ]] && _CHANNEL=slack
    [[ -z "$_CHANNEL" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] && _CHANNEL=telegram
fi

if [[ "$_CHANNEL" == "slack" ]]; then
    curl -sf -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$(jq -n --arg c "$SLACK_CHANNEL" --arg t "$MSG" '{channel:$c, text:$t, unfurl_links:false}')" \
        >/dev/null 2>&1 || true
elif [[ "$_CHANNEL" == "telegram" ]]; then
    curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$TELEGRAM_CHAT_ID" --arg t "$MSG" '{chat_id:$c, text:$t, parse_mode:"Markdown"}')" \
        >/dev/null 2>&1 || true
fi

exit 0
