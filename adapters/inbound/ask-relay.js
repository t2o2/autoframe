/**
 * ask-relay.js — runs inside the slack-listen bot (the single Socket Mode
 * consumer). When a human clicks an ask-human option button, this resolves the
 * chosen label, writes it to Redis for the waiting ask-human.sh process to pick
 * up, and retires the card's buttons.
 *
 * This is the bridge that lets the EPHEMERAL ask-human.sh use buttons without
 * opening its own (conflicting) Socket Mode connection.
 */

import { decodeAskValue, resolveLabel, optsKey, ansKey, askResolvedBlocks } from './ask-buttons.js';

const ANSWER_TTL_SEC = 3700; // outlives ask-human.sh's 1-hour wait + buffer

/**
 * Build the relay handler. `redis` is an ioredis-like client; `slack` is a
 * SlackClient. Returns an async fn taking a block_actions payload.
 */
export function createAskRelay({ redis, slack, ttlSec = ANSWER_TTL_SEC }) {
  return async function handleAskAction(payload) {
    const action = payload.actions?.[0];
    const { key, idx } = decodeAskValue(action?.value);
    if (!key) return;

    const channelId = payload.container?.channel_id ?? payload.channel?.id;
    const messageTs = payload.container?.message_ts;

    const optsJson = await redis.get(optsKey(key));
    const label = resolveLabel(optsJson, idx);

    // Hand the answer to the waiting asker. Empty string == skip/none (still set,
    // so the asker unblocks instead of timing out).
    await redis.set(ansKey(key), label, 'EX', ttlSec);

    if (channelId && messageTs) {
      const header = payload.message?.blocks?.[0]?.text?.text ?? '*Input received*';
      const footer = label
        ? `:white_check_mark: Received — _${label}_`
        : ':fast_forward: Skipped — no answer';
      await slack.updateMessage(channelId, messageTs, footer, askResolvedBlocks(header, footer))
        .catch((err) => console.error(`[ask-relay] updateMessage failed: ${err.message}`));
    }
  };
}
