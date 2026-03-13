#!/usr/bin/env bash
# ask-human.sh
#
# Sends a question with numbered options to Telegram and waits up to 1 hour
# for a reply. Prints the chosen text to stdout so Claude can read it.
#
# Usage:
#   ./scripts/ask-human.sh <ticket_id> "<question>" ["<opt1>" "<opt2>" ...]
#
# Reply formats accepted in Telegram:
#   2         → option 2
#   1,3,5     → options 1, 3, and 5 (multi-select, comma-joined on stdout)
#   all       → all options (comma-joined on stdout)
#   skip      → empty string (agent proceeds with no input)
#   <text>    → free-text passthrough
#
# Exit codes:
#   0  reply received
#   1  timed out — default applied (option 1, or empty if no options given)
#   2  configuration error (missing credentials)

set -uo pipefail

TIMEOUT=3600   # 1 hour

# ── Load credentials ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$(grep -E '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')}"
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set in .env" >&2
    exit 2
fi

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# ── Args ──────────────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
    echo "Usage: ask-human.sh <ticket_id> <question> [option1] [option2] ..." >&2
    exit 2
fi

TICKET_ID="$1"
QUESTION="$2"
shift 2
OPTIONS=("$@")

# ── Helpers ───────────────────────────────────────────────────────────────────

# Send a Telegram message; returns the message_id on stdout.
send_message() {
    local text="$1"
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'chat_id': sys.argv[1],
    'text':    sys.argv[2],
    'parse_mode': 'Markdown',
}))" "$TELEGRAM_CHAT_ID" "$text")

    local resp
    resp=$(curl -sf -X POST "${TELEGRAM_API}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || { echo "" ; return 1; }

    python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('result',{}).get('message_id',''))" \
        <<< "$resp" 2>/dev/null || echo ""
}

# ── Build and send question ───────────────────────────────────────────────────

build_message() {
    python3 -c "
import sys

ticket_id = sys.argv[1]
question  = sys.argv[2]
opts      = sys.argv[3:]

lines = [f'🤖 *{ticket_id}* — Input required', '', question]

if opts:
    lines.append('')
    for i, o in enumerate(opts, 1):
        lines.append(f'{i}) {o}')
    lines.append('')
    lines.append('Reply with a number \`2\`, comma-separated \`1,3\`, \`all\`, \`skip\`, or free text.')
    lines.append('⏱ Waiting 1 hour — default: option 1')
else:
    lines.append('')
    lines.append('Reply with your answer. ⏱ Waiting 1 hour.')

print('\n'.join(lines))
" "$TICKET_ID" "$QUESTION" "${OPTIONS[@]+"${OPTIONS[@]}"}"
}

MSG=$(build_message)

# Get current update offset BEFORE sending so we only read replies to our question
offset_resp=$(curl -sf "${TELEGRAM_API}/getUpdates?limit=1&offset=-1" 2>/dev/null || echo '{"result":[]}')
OFFSET=$(python3 -c "
import json, sys
updates = json.loads(sys.stdin.read()).get('result', [])
print(updates[-1]['update_id'] + 1 if updates else 0)
" <<< "$offset_resp" 2>/dev/null || echo "0")

send_message "$MSG" >/dev/null

# ── Poll for reply ────────────────────────────────────────────────────────────

REPLY=""
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while true; do
    NOW=$(date +%s)
    (( NOW >= DEADLINE )) && break

    REMAINING=$(( DEADLINE - NOW ))
    POLL_TIMEOUT=$(( REMAINING < 30 ? REMAINING : 30 ))
    [[ $POLL_TIMEOUT -le 0 ]] && break

    UPDATES=$(curl -sf \
        "${TELEGRAM_API}/getUpdates?offset=${OFFSET}&timeout=${POLL_TIMEOUT}&allowed_updates=%5B%22message%22%5D" \
        2>/dev/null || echo '{"result":[]}')

    # Extract first message from our chat (skip bot commands)
    RESULT=$(python3 -c "
import json, sys
chat_id = sys.argv[1]
data = json.loads(sys.stdin.read())
last_id = None
found_text = ''
for u in data.get('result', []):
    last_id = u['update_id']
    msg = u.get('message', {})
    if str(msg.get('chat', {}).get('id', '')) == chat_id:
        text = msg.get('text', '')
        if text and not text.startswith('/'):
            print(last_id, text)
            sys.exit(0)
if last_id is not None:
    print(last_id, '')
" "$TELEGRAM_CHAT_ID" <<< "$UPDATES" 2>/dev/null || echo "")

    if [[ -n "$RESULT" ]]; then
        NEW_OFFSET=$(echo "$RESULT" | awk '{print $1}')
        TEXT=$(echo "$RESULT" | cut -d' ' -f2-)
        OFFSET=$(( NEW_OFFSET + 1 ))

        if [[ -n "$TEXT" ]]; then
            REPLY="$TEXT"
            break
        fi
    fi
done

# ── Parse reply ───────────────────────────────────────────────────────────────

parse_reply() {
    local raw="$1"

    if [[ -z "$raw" ]] || [[ "${raw,,}" == "skip" ]]; then
        echo ""
        return
    fi

    if [[ ${#OPTIONS[@]} -eq 0 ]]; then
        echo "$raw"
        return
    fi

    if [[ "${raw,,}" == "all" ]]; then
        python3 -c "import sys; print(', '.join(sys.argv[1:]))" "${OPTIONS[@]}"
        return
    fi

    # Numeric: single "2" or multi "1,3,5"
    if echo "$raw" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
        python3 -c "
import sys
opts = sys.argv[1:-1]
indices_raw = sys.argv[-1]
chosen = []
for idx in indices_raw.split(','):
    pos = int(idx) - 1
    if 0 <= pos < len(opts):
        chosen.append(opts[pos])
print(', '.join(chosen))
" "${OPTIONS[@]}" "$raw"
        return
    fi

    # Free-text fallback
    echo "$raw"
}

# ── Output result ─────────────────────────────────────────────────────────────

TIMED_OUT=false
if [[ -z "$REPLY" ]]; then
    TIMED_OUT=true
    REPLY="${OPTIONS[0]:-}"
fi

CHOSEN=$(parse_reply "$REPLY")

if $TIMED_OUT; then
    TIMEOUT_MSG="⏱ No reply for *${TICKET_ID}* after 1 hour. Proceeding with: *${CHOSEN:-skip}*"
    send_message "$TIMEOUT_MSG" >/dev/null
    echo "$CHOSEN"
    exit 1
fi

CONFIRM_MSG="✅ *${TICKET_ID}*: Received — \"${CHOSEN}\""
send_message "$CONFIRM_MSG" >/dev/null

echo "$CHOSEN"
exit 0
