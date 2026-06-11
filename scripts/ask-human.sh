#!/usr/bin/env bash
# ask-human.sh
#
# Asks a human a question and waits up to 1 hour for the answer, printing the
# chosen option text to stdout so the agent can read it. Channel-agnostic:
#
#   • Slack    (preferred) — set SLACK_BOT_TOKEN (+ SLACK_CHANNEL). Posts the
#     question to the channel; the human replies IN THE THREAD with the option
#     number or free text. Zero infra: needs only a bot token with chat:write
#     and channels:history (or groups:history for a private channel), and the
#     bot invited to the channel. No interactivity Request URL / Socket Mode.
#   • Telegram (fallback)  — set TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID. Uses
#     tappable inline-keyboard buttons.
#
# Either way it also @-mentions the ticket owner on Linear so the right human is
# pinged there too (best-effort; never blocks the ask).
#
# Usage:
#   ./scripts/ask-human.sh <ticket_id> "<question>" ["<opt1>" "<opt2>" ...]
#
# Exit codes:
#   0  answer received
#   1  timed out — default applied (option 1, or empty if no options given)
#   2  configuration error (no channel credentials)

set -uo pipefail

TIMEOUT=3600   # 1 hour

# ── Load credentials ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

read_env() {  # $1 = key; echoes value from process env or .env file
    local k="$1" v="${!1:-}"
    if [[ -z "$v" && -f "$ENV_FILE" ]]; then
        v="$(grep -E "^${k}=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
    fi
    echo "$v"
}

SLACK_BOT_TOKEN="$(read_env SLACK_BOT_TOKEN)"
SLACK_CHANNEL="$(read_env SLACK_CHANNEL)"
TELEGRAM_BOT_TOKEN="$(read_env TELEGRAM_BOT_TOKEN)"
TELEGRAM_CHAT_ID="$(read_env TELEGRAM_CHAT_ID)"
LINEAR_API_KEY="$(read_env LINEAR_API_KEY)"

if [[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_CHANNEL" ]]; then
    CHANNEL=slack
elif [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    CHANNEL=telegram
else
    echo "ERROR: no feedback channel configured. Set SLACK_BOT_TOKEN + SLACK_CHANNEL (preferred) or TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID in .env" >&2
    exit 2
fi

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

# ── Shared: @-mention the Linear ticket owner ─────────────────────────────────

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
lines += ['', '_Reply on the feedback channel, or comment here._']
print('\n'.join(lines))
" "$owner_url" "$TICKET_ID" "$QUESTION" "${OPTIONS[@]+"${OPTIONS[@]}"}")
    curl -sf -X POST "$LINEAR_API" \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        --data "$(jq -n --arg i "$TICKET_ID" --arg b "$body" \
            '{query:"mutation($i:String!,$b:String!){commentCreate(input:{issueId:$i,body:$b}){success}}", variables:{i:$i, b:$b}}')" \
        >/dev/null 2>&1 || return 0
}

# ── Shared: resolve a free-text / numeric reply to an option ──────────────────
#   empty / "skip" → ""   |   "<n>" (1-indexed) → OPTIONS[n-1]   |   else raw text
resolve_text() {
    local raw="$1"
    python3 -c "
import sys
raw = sys.argv[1].strip()
opts = sys.argv[2:]
low = raw.lower()
if not raw or low == 'skip':
    print(''); sys.exit(0)
if raw.isdigit():
    i = int(raw) - 1
    print(opts[i] if 0 <= i < len(opts) else '')
    sys.exit(0)
print(raw)
" "$raw" "${OPTIONS[@]+"${OPTIONS[@]}"}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Slack channel
# ══════════════════════════════════════════════════════════════════════════════

slack_api() {  # $1 = method, $2 = json body → raw response on stdout
    curl -sf -X POST "https://slack.com/api/$1" \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$2" 2>/dev/null || echo '{"ok":false}'
}

run_slack() {
    local text resp ts channel_id bot_user_id
    text=$(python3 -c "
import sys
ticket, question = sys.argv[1], sys.argv[2]
opts = sys.argv[3:]
lines = [f':robot_face: *{ticket}* — input required', '', question]
if opts:
    lines.append('')
    for i, o in enumerate(opts, 1):
        lines.append(f'  *{i}.* {o}')
    lines += ['', '_Reply in this thread with the option number (or your own answer). Waiting 1 hour — default: option 1._']
else:
    lines += ['', '_Reply in this thread with your answer. Waiting 1 hour._']
print('\n'.join(lines))
" "$TICKET_ID" "$QUESTION" "${OPTIONS[@]+"${OPTIONS[@]}"}")

    # Post the question (thread root).
    resp=$(slack_api chat.postMessage "$(jq -n --arg c "$SLACK_CHANNEL" --arg t "$text" \
        '{channel:$c, text:$t, unfurl_links:false}')")
    if [[ "$(jq -r '.ok' <<< "$resp" 2>/dev/null)" != "true" ]]; then
        echo "ERROR: Slack chat.postMessage failed: $(jq -r '.error // "unknown"' <<< "$resp" 2>/dev/null)" >&2
        echo "${OPTIONS[0]:-}"; exit 2
    fi
    ts=$(jq -r '.ts' <<< "$resp")
    channel_id=$(jq -r '.channel' <<< "$resp")   # resolved id (works even if SLACK_CHANNEL was a name)
    bot_user_id=$(jq -r '.user // empty' <<< "$(slack_api auth.test '{}')")

    notify_ticket_owner

    # Poll the thread for the first human (non-bot) reply.
    local deadline now chosen reply
    deadline=$(( $(date +%s) + TIMEOUT ))
    reply=""
    while true; do
        now=$(date +%s); (( now >= deadline )) && break
        resp=$(slack_api conversations.replies "$(jq -n --arg c "$channel_id" --arg ts "$ts" \
            '{channel:$c, ts:$ts, limit:50}')")
        reply=$(python3 -c "
import json, sys
root_ts, bot_uid = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
for m in data.get('messages', []):
    if m.get('ts') == root_ts:        # skip the question itself
        continue
    if m.get('bot_id') or m.get('subtype'):   # skip bot/system messages
        continue
    if bot_uid and m.get('user') == bot_uid:  # skip our own user, just in case
        continue
    txt = (m.get('text') or '').strip()
    if txt:
        print(txt); break
" "$ts" "${bot_user_id:-}" <<< "$resp" 2>/dev/null || echo "")
        [[ -n "$reply" ]] && break
        sleep 10
    done

    if [[ -z "$reply" ]]; then
        chosen="${OPTIONS[0]:-}"
        slack_api chat.postMessage "$(jq -n --arg c "$channel_id" --arg ts "$ts" \
            --arg t ":hourglass: No reply for *${TICKET_ID}* after 1 hour. Proceeding with: *${chosen:-skip}*" \
            '{channel:$c, thread_ts:$ts, text:$t}')" >/dev/null
        echo "$chosen"; exit 1
    fi

    chosen="$(resolve_text "$reply")"
    slack_api chat.postMessage "$(jq -n --arg c "$channel_id" --arg ts "$ts" \
        --arg t ":white_check_mark: *${TICKET_ID}*: received — \"${chosen:-skip}\"" \
        '{channel:$c, thread_ts:$ts, text:$t}')" >/dev/null
    echo "$chosen"; exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Telegram channel (fallback)
# ══════════════════════════════════════════════════════════════════════════════

run_telegram() {
    local TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

    send_message() {
        local text="$1" payload resp
        payload=$(python3 -c "
import json, sys
print(json.dumps({'chat_id': sys.argv[1], 'text': sys.argv[2], 'parse_mode': 'Markdown'}))" \
            "$TELEGRAM_CHAT_ID" "$text")
        resp=$(curl -sf -X POST "${TELEGRAM_API}/sendMessage" -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || { echo ""; return 1; }
        python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('result',{}).get('message_id',''))" <<< "$resp" 2>/dev/null || echo ""
    }
    build_keyboard() {
        python3 -c "
import json, sys
opts = sys.argv[1:]
rows = [[{'text': o, 'callback_data': str(i)}] for i, o in enumerate(opts)]
rows.append([{'text': '⏭ Skip', 'callback_data': 'skip'}])
print(json.dumps({'inline_keyboard': rows}))" "${OPTIONS[@]+"${OPTIONS[@]}"}"
    }
    send_question() {
        local text="$1" markup="" payload resp
        [[ ${#OPTIONS[@]} -gt 0 ]] && markup="$(build_keyboard)"
        payload=$(python3 -c "
import json, sys
p = {'chat_id': sys.argv[1], 'text': sys.argv[2], 'parse_mode': 'Markdown'}
if len(sys.argv) > 3 and sys.argv[3]:
    p['reply_markup'] = json.loads(sys.argv[3])
print(json.dumps(p))" "$TELEGRAM_CHAT_ID" "$text" "$markup")
        resp=$(curl -sf -X POST "${TELEGRAM_API}/sendMessage" -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || { echo ""; return 1; }
        jq -r '.result.message_id // empty' <<< "$resp" 2>/dev/null || echo ""
    }
    answer_callback() {
        [[ -z "${1:-}" ]] && return 0
        curl -sf -X POST "${TELEGRAM_API}/answerCallbackQuery" -H "Content-Type: application/json" \
            -d "$(jq -n --arg id "$1" '{callback_query_id:$id}')" >/dev/null 2>&1 || true
    }
    edit_question() {
        [[ -z "${1:-}" ]] && return 1
        curl -sf -X POST "${TELEGRAM_API}/editMessageText" -H "Content-Type: application/json" \
            -d "$(python3 -c "
import json, sys
print(json.dumps({'chat_id': sys.argv[1], 'message_id': int(sys.argv[2]), 'text': sys.argv[3], 'parse_mode': 'Markdown'}))" \
                "$TELEGRAM_CHAT_ID" "$1" "$2")" >/dev/null 2>&1
    }
    local MSG
    MSG=$(python3 -c "
import sys
ticket_id, question = sys.argv[1], sys.argv[2]
opts = sys.argv[3:]
lines = [f'🤖 *{ticket_id}* — Input required', '', question]
if opts:
    lines += ['', '👇 Tap a button to answer.', '⏱ Waiting 1 hour — default: option 1']
else:
    lines += ['', 'Reply to this message with your answer. ⏱ Waiting 1 hour.']
print('\n'.join(lines))" "$TICKET_ID" "$QUESTION" "${OPTIONS[@]+"${OPTIONS[@]}"}")

    local offset_resp OFFSET QUESTION_MSG_ID
    offset_resp=$(curl -sf "${TELEGRAM_API}/getUpdates?limit=1&offset=-1" 2>/dev/null || echo '{"result":[]}')
    OFFSET=$(python3 -c "
import json, sys
updates = json.loads(sys.stdin.read()).get('result', [])
print(updates[-1]['update_id'] + 1 if updates else 0)" <<< "$offset_resp" 2>/dev/null || echo "0")

    QUESTION_MSG_ID=$(send_question "$MSG")
    notify_ticket_owner

    local REPLY="" REPLY_KIND="" DEADLINE NOW REMAINING POLL_TIMEOUT UPDATES RESULT NEW_OFFSET
    DEADLINE=$(( $(date +%s) + TIMEOUT ))
    while true; do
        NOW=$(date +%s); (( NOW >= DEADLINE )) && break
        REMAINING=$(( DEADLINE - NOW )); POLL_TIMEOUT=$(( REMAINING < 30 ? REMAINING : 30 ))
        [[ $POLL_TIMEOUT -le 0 ]] && break
        UPDATES=$(curl -sf "${TELEGRAM_API}/getUpdates?offset=${OFFSET}&timeout=${POLL_TIMEOUT}&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D" 2>/dev/null || echo '{"result":[]}')
        RESULT=$(python3 -c "
import json, sys
chat_id, our_msg_id = sys.argv[1], sys.argv[2]
data = json.loads(sys.stdin.read())
last_id = None
for u in data.get('result', []):
    last_id = u['update_id']
    cq = u.get('callback_query')
    if cq:
        m = cq.get('message', {}) or {}
        if str(m.get('chat', {}).get('id','')) == chat_id and str(m.get('message_id','')) == our_msg_id:
            print(json.dumps({'offset': last_id, 'kind': 'callback', 'data': cq.get('data',''), 'cq_id': cq.get('id','')})); sys.exit(0)
        continue
    m = u.get('message', {}) or {}
    if str(m.get('chat', {}).get('id','')) == chat_id:
        text = m.get('text','')
        if text and not text.startswith('/'):
            print(json.dumps({'offset': last_id, 'kind': 'text', 'data': text})); sys.exit(0)
if last_id is not None:
    print(json.dumps({'offset': last_id, 'kind': 'none', 'data': ''}))
" "$TELEGRAM_CHAT_ID" "${QUESTION_MSG_ID:-}" <<< "$UPDATES" 2>/dev/null || echo "")
        [[ -z "$RESULT" ]] && continue
        NEW_OFFSET=$(jq -r '.offset // empty' <<< "$RESULT" 2>/dev/null)
        [[ -n "$NEW_OFFSET" ]] && OFFSET=$(( NEW_OFFSET + 1 ))
        case "$(jq -r '.kind // "none"' <<< "$RESULT" 2>/dev/null)" in
            callback)
                answer_callback "$(jq -r '.cq_id // empty' <<< "$RESULT")"
                REPLY="$(jq -r '.data // empty' <<< "$RESULT")"; REPLY_KIND="callback"; break ;;
            text)
                REPLY="$(jq -r '.data // empty' <<< "$RESULT")"; REPLY_KIND="text"; break ;;
        esac
    done

    local CHOSEN RESOLVE_MSG
    if [[ -z "$REPLY_KIND" ]]; then
        CHOSEN="${OPTIONS[0]:-}"
        RESOLVE_MSG="⏱ No reply for *${TICKET_ID}* after 1 hour. Proceeding with: *${CHOSEN:-skip}*"
        edit_question "$QUESTION_MSG_ID" "$RESOLVE_MSG" || send_message "$RESOLVE_MSG" >/dev/null
        echo "$CHOSEN"; exit 1
    fi
    # callback data is a 0-indexed option; map to the same 1-indexed resolver input.
    if [[ "$REPLY_KIND" == "callback" ]]; then
        if [[ -z "$REPLY" || "$REPLY" == "skip" ]]; then CHOSEN=""
        else CHOSEN="$(resolve_text "$(( REPLY + 1 ))")"; fi
    else
        CHOSEN="$(resolve_text "$REPLY")"
    fi
    RESOLVE_MSG="✅ *${TICKET_ID}*: Received — \"${CHOSEN:-skip}\""
    edit_question "$QUESTION_MSG_ID" "$RESOLVE_MSG" || send_message "$RESOLVE_MSG" >/dev/null
    echo "$CHOSEN"; exit 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$CHANNEL" in
    slack)    run_slack ;;
    telegram) run_telegram ;;
esac
