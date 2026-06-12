/**
 * ask-human-slack.mjs — Slack BUTTON path for ask-human.sh (options case).
 *
 * Posts the question as Block Kit option buttons (bot token only — NO Socket
 * Mode here) and waits for the answer via Redis. The slack-listen bot is the
 * single Socket Mode consumer: it receives the click and writes the chosen
 * label to Redis, which we poll for here.
 *
 * Usage:   node ask-human-slack.mjs <ticket_id> <question> <opt1> [opt2 ...]
 * Env:     SLACK_BOT_TOKEN, SLACK_CHANNEL, REDIS_URL, ASK_TIMEOUT (sec, def 3600)
 * Stdout:  the chosen option text (empty line = skip / timeout-default-skip)
 * Exit:    0 answered · 1 timed out (default applied) · 2 config error
 *          75 cannot use buttons (no REDIS_URL) → caller should fall back
 */

import { randomBytes } from 'node:crypto';
import { SlackClient } from '../adapters/outbound/slack-client.js';
import { askBlocks, askResolvedBlocks, optsKey, ansKey } from '../adapters/inbound/ask-buttons.js';

const [, , ticketId, question, ...options] = process.argv;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fail = (msg, code) => { console.error(`ask-human-slack: ${msg}`); process.exit(code); };

if (!ticketId || !question) fail('usage: ask-human-slack.mjs <ticket> <question> <opt...>', 2);
if (options.length === 0) fail('no options — buttons require at least one option', 2);

const botToken = process.env.SLACK_BOT_TOKEN;
const channel = process.env.SLACK_CHANNEL;
const redisUrl = process.env.REDIS_URL;
const timeoutSec = Number.parseInt(process.env.ASK_TIMEOUT ?? '3600', 10) || 3600;

if (!botToken || !channel) fail('SLACK_BOT_TOKEN and SLACK_CHANNEL are required', 2);
// No Redis → we cannot coordinate with the Socket Mode consumer. Signal the
// caller (ask-human.sh) to fall back to the legacy thread-reply flow.
if (!redisUrl) fail('REDIS_URL unset — cannot use Slack buttons', 75);

const { default: Redis } = await import('ioredis');

const key = `${ticketId}:${randomBytes(6).toString('hex')}`;
const ttlSec = timeoutSec + 100;

const header = [
  `:robot_face: *${ticketId}* — input required`,
  '',
  question,
  '',
  '_Tap a button below. Waiting 1 hour — default: the first option._',
].join('\n');

const slack = new SlackClient(botToken);
const redis = new Redis(redisUrl, { maxRetriesPerRequest: 3 });
redis.on('error', (err) => console.error(`ask-human-slack: redis: ${err.message}`));

let channelId;
let messageTs;

async function cleanup(code) {
  try { await redis.quit(); } catch { /* ignore */ }
  process.exit(code);
}

try {
  channelId = await slack.resolveChannelId(channel);

  // Store options BEFORE posting so an instant click can resolve the label.
  await redis.set(optsKey(key), JSON.stringify(options), 'EX', ttlSec);

  const posted = await slack.postBlocks(channelId, `${ticketId}: input required`, askBlocks(header, options, key));
  messageTs = posted.ts;
} catch (err) {
  fail(`failed to post question: ${err.message}`, 2);
}

// Poll Redis for the relayed answer.
const deadline = Date.now() + timeoutSec * 1000;
while (Date.now() < deadline) {
  const ans = await redis.get(ansKey(key));
  if (ans !== null) {
    process.stdout.write(`${ans}\n`); // slack-listen already retired the card
    await cleanup(0);
  }
  await sleep(3000);
}

// Timed out — apply the default (first option) and retire the card ourselves.
const fallback = options[0] ?? '';
const footer = `:hourglass: No reply for *${ticketId}* after 1 hour. Proceeding with: *${fallback || 'skip'}*`;
await slack.updateMessage(channelId, messageTs, footer, askResolvedBlocks(header, footer))
  .catch((err) => console.error(`ask-human-slack: updateMessage failed: ${err.message}`));
process.stdout.write(`${fallback}\n`);
await cleanup(1);
