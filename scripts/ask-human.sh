#!/usr/bin/env bash
# ask-human.sh
#
# Asks a question on Telegram with tappable inline-keyboard buttons and waits up
# to 1 hour for the answer. Prints the chosen option text to stdout so Claude can
# read it. Also @-mentions the ticket owner on Linear so the right human is pinged.
#
# Usage:
#   ./scripts/ask-human.sh <ticket_id> "<question>" ["<opt1>" "<opt2>" ...]
#
# With options: each becomes a button; tapping one prints that option's text.
#   A "⏭ Skip" button prints an empty string (agent proceeds with no input).
#   Button taps (callback queries) reach the bot even with group privacy mode on.
# Without options: the user replies to the message with free text (printed as-is);
#   this needs privacy mode off or a direct reply, since it's read via getUpdates.
#
# Exit codes:
#   0  answer received
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
    LINEAR_API_KEY="${LINEAR_API_KEY:-$(grep -E '^LINEAR_API_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')}"
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set in .env" >&2
    exit 2
fi

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
LINEAR_API="https://api.linear.app/graphql"

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

# @-mention the ticket owner in a Linear comment so the responsible human is
# notified there too — not only on Telegram (and not at all when the agent runs
# headless, where interactive prompts reach nobody). Owner = assignee, falling
# back to creator. Best-effort: any failure here must never block the ask.
notify_ticket_owner() {
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 0

    local resp owner_url
    resp=$(curl -sf -X POST "$LINEAR_API" \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        --data "$(jq -n --arg id "$TICKET_ID" \
            '{query:"query($id:String!){issue(id:$id){assignee{url} creator{url}}}", variables:{id:$id}}')" \
        2>/dev/null) || return 0

    owner_url=$(jq -r '.data.issue.assignee.url // .data.issue.creator.url // empty' <<< "$resp" 2>/dev/null || echo "")
    [[ -z "$owner_url" ]] && return 0

    # A bare profile URL is how the Linear API turns text into an @-mention —
    # it must stay unwrapped (no [text](url) link, no code block) to convert.
    local body
    body=$(python3 -c "
import sys
owner, ticket, question = sys.argv[1], sys.argv[2], sys.argv[3]
opts = sys.argv[4:]
lines = [f'{owner} — 🤖 input needed on **{ticket}**', '', question]
if opts:
    lines.append('')
    for i, o in enumerate(opts, 1):
        lines.append(f'{i}. {o}')
lines += ['', '_Reply on Telegram, or comment here._']
print('\n'.join(lines))
" "$owner_url" "$TICKET_ID" "$QUESTION" "${OPTIONS[@]+"${OPTIONS[@]}"}")

    curl -sf -X POST "$LINEAR_API" \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        --data "$(jq -n --arg i "$TICKET_ID" --arg b "$body" \
            '{query:"mutation($i:String!,$b:String!){commentCreate(input:{issueId:$i,body:$b}){success}}", variables:{i:$i, b:$b}}')" \
        >/dev/null 2>&1 || return 0
}

# Build an inline-keyboard reply_markup: one button per option + a Skip button.
# callback_data is the option index — Telegram caps it at 64 bytes, so we never
# send the (possibly long) option text back over the wire.
build_keyboard() {
    python3 -c "
import json, sys
opts = sys.argv[1:]
rows = [[{'text': o, 'callback_data': str(i)}] for i, o in enumerate(opts)]
rows.append([{'text': '⏭ Skip', 'callback_data': 'skip'}])
print(json.dumps({'inline_keyboard': rows}))
" "${OPTIONS[@]+"${OPTIONS[@]}"}"
}

# Send the question. When options exist, attaches tappable buttons; callback
# queries from those buttons reach the bot even with group privacy mode ON.
# Prints the sent message_id on stdout (needed to match button taps to us).
send_question() {
    local text="$1" markup="" payload resp
    [[ ${#OPTIONS[@]} -gt 0 ]] && markup="$(build_keyboard)"
    payload=$(python3 -c "
import json, sys
p = {'chat_id': sys.argv[1], 'text': sys.argv[2], 'parse_mode': 'Markdown'}
if len(sys.argv) > 3 and sys.argv[3]:
    p['reply_markup'] = json.loads(sys.argv[3])
print(json.dumps(p))
" "$TELEGRAM_CHAT_ID" "$text" "$markup")
    resp=$(curl -sf -X POST "${TELEGRAM_API}/sendMessage" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || { echo ""; return 1; }
    jq -r '.result.message_id // empty' <<< "$resp" 2>/dev/null || echo ""
}

# Acknowledge a button tap so the client stops showing a loading spinner.
answer_callback() {
    [[ -z "${1:-}" ]] && return 0
    curl -sf -X POST "${TELEGRAM_API}/answerCallbackQuery" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg id "$1" '{callback_query_id:$id}')" >/dev/null 2>&1 || true
}

# Edit the question message to show the resolution and drop the keyboard, so the
# buttons can't be tapped twice. Best-effort. $1=message_id $2=text
edit_question() {
    [[ -z "${1:-}" ]] && return 1
    curl -sf -X POST "${TELEGRAM_API}/editMessageText" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "
import json, sys
print(json.dumps({'chat_id': sys.argv[1], 'message_id': int(sys.argv[2]), 'text': sys.argv[3], 'parse_mode': 'Markdown'}))
" "$TELEGRAM_CHAT_ID" "$1" "$2")" >/dev/null 2>&1
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
    lines.append('👇 Tap a button to answer.')
    lines.append('⏱ Waiting 1 hour — default: option 1')
else:
    lines.append('')
    lines.append('Reply to this message with your answer. ⏱ Waiting 1 hour.')

print('\n'.join(lines))
" "$TICKET_ID" "$QUESTION" "${OPTIONS[@]+"${OPTIONS[@]}"}"
}

MSG=$(build_message)

# Capture the update offset BEFORE sending so we only read replies to our question.
offset_resp=$(curl -sf "${TELEGRAM_API}/getUpdates?limit=1&offset=-1" 2>/dev/null || echo '{"result":[]}')
OFFSET=$(python3 -c "
import json, sys
updates = json.loads(sys.stdin.read()).get('result', [])
print(updates[-1]['update_id'] + 1 if updates else 0)
" <<< "$offset_resp" 2>/dev/null || echo "0")

QUESTION_MSG_ID=$(send_question "$MSG")
notify_ticket_owner

# ── Poll for a button tap (or a typed reply) ──────────────────────────────────

REPLY=""        # callback data ("0".."N-1" / "skip") or free text
REPLY_KIND=""   # "callback" | "text" — empty means no answer yet
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while true; do
    NOW=$(date +%s)
    (( NOW >= DEADLINE )) && break

    REMAINING=$(( DEADLINE - NOW ))
    POLL_TIMEOUT=$(( REMAINING < 30 ? REMAINING : 30 ))
    [[ $POLL_TIMEOUT -le 0 ]] && break

    # allowed_updates = ["message","callback_query"]
    UPDATES=$(curl -sf \
        "${TELEGRAM_API}/getUpdates?offset=${OFFSET}&timeout=${POLL_TIMEOUT}&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D" \
        2>/dev/null || echo '{"result":[]}')

    # First update that belongs to us: a button tap on OUR message, or a
    # (non-command) text message in our chat. Emits one JSON object.
    RESULT=$(python3 -c "
import json, sys
chat_id    = sys.argv[1]
our_msg_id = sys.argv[2]
data = json.loads(sys.stdin.read())
last_id = None
for u in data.get('result', []):
    last_id = u['update_id']
    cq = u.get('callback_query')
    if cq:
        m = cq.get('message', {}) or {}
        if str(m.get('chat', {}).get('id','')) == chat_id and str(m.get('message_id','')) == our_msg_id:
            print(json.dumps({'offset': last_id, 'kind': 'callback', 'data': cq.get('data',''), 'cq_id': cq.get('id','')}))
            sys.exit(0)
        continue
    m = u.get('message', {}) or {}
    if str(m.get('chat', {}).get('id','')) == chat_id:
        text = m.get('text','')
        if text and not text.startswith('/'):
            print(json.dumps({'offset': last_id, 'kind': 'text', 'data': text}))
            sys.exit(0)
if last_id is not None:
    print(json.dumps({'offset': last_id, 'kind': 'none', 'data': ''}))
" "$TELEGRAM_CHAT_ID" "${QUESTION_MSG_ID:-}" <<< "$UPDATES" 2>/dev/null || echo "")

    [[ -z "$RESULT" ]] && continue

    NEW_OFFSET=$(jq -r '.offset // empty' <<< "$RESULT" 2>/dev/null)
    [[ -n "$NEW_OFFSET" ]] && OFFSET=$(( NEW_OFFSET + 1 ))

    case "$(jq -r '.kind // "none"' <<< "$RESULT" 2>/dev/null)" in
        callback)
            answer_callback "$(jq -r '.cq_id // empty' <<< "$RESULT")"
            REPLY="$(jq -r '.data // empty' <<< "$RESULT")"
            REPLY_KIND="callback"
            break ;;
        text)
            REPLY="$(jq -r '.data // empty' <<< "$RESULT")"
            REPLY_KIND="text"
            break ;;
    esac
done

# ── Resolve the chosen answer ─────────────────────────────────────────────────

# Map a reply to the answer text printed on stdout.
#   callback "skip"/"" → ""    callback "<n>" → OPTIONS[n]
#   text "skip"/""     → ""    text "<other>" → raw text
resolve() {
    local kind="$1" raw="$2"
    if [[ "$kind" == "callback" ]]; then
        [[ -z "$raw" || "$raw" == "skip" ]] && { echo ""; return; }
        python3 -c "
import sys
opts = sys.argv[1:-1]
i = int(sys.argv[-1])
print(opts[i] if 0 <= i < len(opts) else '')
" "${OPTIONS[@]+"${OPTIONS[@]}"}" "$raw"
        return
    fi
    [[ -z "$raw" || "${raw,,}" == "skip" ]] && { echo ""; return; }
    echo "$raw"
}

# ── Output result ─────────────────────────────────────────────────────────────

if [[ -z "$REPLY_KIND" ]]; then
    CHOSEN="${OPTIONS[0]:-}"   # timeout → default to option 1 (empty if none)
    RESOLVE_MSG="⏱ No reply for *${TICKET_ID}* after 1 hour. Proceeding with: *${CHOSEN:-skip}*"
    edit_question "$QUESTION_MSG_ID" "$RESOLVE_MSG" || send_message "$RESOLVE_MSG" >/dev/null
    echo "$CHOSEN"
    exit 1
fi

CHOSEN=$(resolve "$REPLY_KIND" "$REPLY")
RESOLVE_MSG="✅ *${TICKET_ID}*: Received — \"${CHOSEN:-skip}\""
edit_question "$QUESTION_MSG_ID" "$RESOLVE_MSG" || send_message "$RESOLVE_MSG" >/dev/null

echo "$CHOSEN"
exit 0
