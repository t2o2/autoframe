/**
 * slack-listener.js — polls a Slack channel for new messages and orchestrates
 * ticket refinement conversations via Claude, then creates Linear tickets.
 *
 * Any root (non-thread) message from a human in the configured channel starts
 * a new refinement thread. Replies to that thread continue the conversation.
 *
 * Required env vars (loaded by caller from .env):
 *   SLACK_BOT_TOKEN       xoxb-...
 *   SLACK_TICKET_CHANNEL  channel name or ID (defaults to SLACK_CHANNEL)
 *   ANTHROPIC_API_KEY     sk-ant-...
 *   LINEAR_API_KEY        lin_api_...
 *   LINEAR_TEAM_KEY       e.g. ENG
 */

import { SlackClient } from '../outbound/slack-client.js';
import { LinearIssueCreator } from '../outbound/linear-issue-creator.js';
import { ClaudeChat } from '../outbound/claude-chat.js';
import { TicketRefiner, renderDraftSummary } from '../../core/ticket-refiner.js';
import { SlackSocket } from './slack-socket.js';
import { approvalBlocks, resolvedBlocks, ACTION_APPROVE, ACTION_DECLINE } from './slack-blocks.js';
import { isAskAction } from './ask-buttons.js';
import { createAskRelay } from './ask-relay.js';

const POLL_INTERVAL_MS = 5_000;

/**
 * Start the polling loop. Never resolves (runs until process exits).
 *
 * @param {{
 *   slackToken: string,
 *   slackAppToken: string,
 *   ticketChannel: string,
 *   anthropicApiKey: string,
 *   linearApiKey: string,
 *   linearTeamKey: string,
 *   redisUrl?: string,
 *   pollIntervalMs?: number,
 * }} opts
 */
export async function startSlackListener({
  slackToken,
  slackAppToken,
  ticketChannel,
  anthropicApiKey,
  linearApiKey,
  linearTeamKey,
  redisUrl,
  pollIntervalMs = POLL_INTERVAL_MS,
}) {
  const slack = new SlackClient(slackToken);
  const linear = new LinearIssueCreator(linearApiKey, linearTeamKey);
  const claude = new ClaudeChat(anthropicApiKey);
  const refiner = new TicketRefiner(claude);

  const channelId = await slack.resolveChannelId(ticketChannel);
  console.log(`[slack-listener] channel=${ticketChannel} (${channelId}) poll=${pollIntervalMs}ms`);

  // ── ask-human relay ────────────────────────────────────────────────────────
  // This bot is the SOLE Socket Mode consumer for the app, so it also relays
  // ask-human.sh's button clicks back to the waiting CLI via Redis.
  let askRelay = null;
  if (redisUrl) {
    const { default: Redis } = await import('ioredis');
    const redis = new Redis(redisUrl, { lazyConnect: false, maxRetriesPerRequest: 3 });
    redis.on('error', (err) => console.error('[slack-listener] redis error:', err.message));
    askRelay = createAskRelay({ redis, slack });
    console.log('[slack-listener] ask-human button relay enabled (Redis)');
  } else {
    console.log('[slack-listener] REDIS_URL unset — ask-human Slack buttons disabled');
  }

  // ── Interactivity (button clicks) over Socket Mode ─────────────────────────
  // Maps the draft card's message ts → { threadTs, summary } so a click can
  // route back to the right conversation and retire the buttons afterwards.
  const draftCards = new Map();
  const socket = new SlackSocket(slackAppToken);
  socket.onBlockAction = (payload) => onBlockAction(payload).catch((err) =>
    console.error('[slack-listener] block action error:', err.message));
  await socket.start();

  // Only process messages posted after startup.
  let channelWatermark = String(Date.now() / 1000);

  // Map<threadTs, lastSeenReplyTs> — tracks threads with active conversations.
  const threadWatermarks = new Map();

  while (true) {
    try {
      await poll();
    } catch (err) {
      console.error('[slack-listener] poll error:', err.message);
    }
    await sleep(pollIntervalMs);
  }

  async function poll() {
    // ── New root messages ────────────────────────────────────────────────────
    const history = await slack.getChannelHistory(channelId, { oldest: channelWatermark });
    const rootMessages = (history.messages ?? [])
      .filter((m) => !m.thread_ts || m.thread_ts === m.ts)
      .filter((m) => !m.bot_id && !m.subtype)
      .filter((m) => m.ts > channelWatermark)
      .reverse(); // oldest first

    for (const msg of rootMessages) {
      channelWatermark = msg.ts;
      const text = (msg.text ?? '').trim();
      if (!text) continue;

      threadWatermarks.set(msg.ts, msg.ts);
      await onNewMessage(channelId, msg.ts, text);
    }

    // ── Thread replies in active conversations ───────────────────────────────
    for (const [threadTs, lastSeen] of [...threadWatermarks.entries()]) {
      const conv = refiner.get(threadTs);
      if (conv?.status === 'done' || conv?.status === 'cancelled') {
        threadWatermarks.delete(threadTs);
        continue;
      }

      let data;
      try {
        data = await slack.getThreadReplies(channelId, threadTs, lastSeen);
      } catch (err) {
        console.error(`[slack-listener] thread ${threadTs} replies error: ${err.message}`);
        continue;
      }

      const newReplies = (data.messages ?? [])
        .filter((m) => m.ts !== threadTs)       // skip root
        .filter((m) => !m.bot_id && !m.subtype) // skip bot messages
        .filter((m) => m.ts > lastSeen)
        .reverse();

      for (const reply of newReplies) {
        threadWatermarks.set(threadTs, reply.ts);
        const text = (reply.text ?? '').trim();
        if (!text) continue;
        await onThreadReply(channelId, threadTs, reply.ts, text);
      }
    }
  }

  async function onNewMessage(channelId, threadTs, userText) {
    console.log(`[slack-listener] new message thread=${threadTs} text="${userText.slice(0, 80)}"`);
    await runTurn(channelId, threadTs, userText, threadTs);
  }

  async function onThreadReply(channelId, threadTs, replyTs, userText) {
    console.log(`[slack-listener] thread reply thread=${threadTs} text="${userText.slice(0, 80)}"`);
    await runTurn(channelId, threadTs, userText, replyTs);
  }

  // `reactTs` is the ts of the user's message we acknowledge with :eyes: while
  // processing, then clear once we've replied.
  async function runTurn(channelId, threadTs, userText, reactTs) {
    let reacted = false;
    try {
      await slack.addReaction(channelId, reactTs);
      reacted = true;
    } catch (err) {
      console.error(`[slack-listener] addReaction failed for ${reactTs}: ${err.message}`);
    }

    const clearReaction = async () => {
      if (!reacted) return;
      await slack.removeReaction(channelId, reactTs)
        .catch((err) => console.error(`[slack-listener] removeReaction failed for ${reactTs}: ${err.message}`));
    };

    let result;
    try {
      result = await refiner.processMessage(threadTs, userText);
    } catch (err) {
      console.error('[slack-listener] Claude error:', err.message);
      await slack.replyInThread(channelId, threadTs, `:x: Claude error: ${err.message}`).catch(() => {});
      await clearReaction();
      return;
    }

    if (!result) {
      await clearReaction();
      return;
    }

    try {
      if (result.type === 'reply') {
        await slack.replyInThread(channelId, threadTs, result.text);
      } else if (result.type === 'cancelled') {
        await slack.replyInThread(channelId, threadTs, ':wave: Ticket creation cancelled.');
      } else if (result.type === 'draft') {
        await presentDraft(channelId, threadTs, result.draft);
      }
    } catch (err) {
      console.error(`[slack-listener] failed to post reply for thread ${threadTs}: ${err.message}`);
    } finally {
      await clearReaction();
    }
  }

  // Post the draft as an approval card. The user responds with the Create/Cancel
  // BUTTONS (Block Kit) — never by typing "yes".
  async function presentDraft(channelId, threadTs, draft) {
    const summary = renderDraftSummary(draft);
    const posted = await slack.postBlocksInThread(
      channelId,
      threadTs,
      'Review the draft ticket and choose an action.',
      approvalBlocks(summary, threadTs),
    );
    if (posted?.ts) draftCards.set(posted.ts, { threadTs, summary });
  }

  // Handle a button click delivered over Socket Mode.
  async function onBlockAction(payload) {
    const action = payload.actions?.[0];
    if (!action) return;

    // ask-human.sh's option buttons — relay the answer through Redis.
    if (isAskAction(action.action_id)) {
      if (askRelay) await askRelay(payload);
      return;
    }

    const messageTs = payload.container?.message_ts;
    const card = messageTs ? draftCards.get(messageTs) : null;
    const threadTs = action.value || card?.threadTs;
    if (!threadTs) return;
    const summary = card?.summary ?? '';

    if (action.action_id === ACTION_APPROVE) {
      const draft = refiner.approve(threadTs);
      if (!draft) return; // already handled (double click) or no draft
      draftCards.delete(messageTs);
      await retireCard(messageTs, summary, ':hourglass_flowing_sand: Creating ticket…');
      await createTicket(channelId, threadTs, draft, messageTs, summary);
    } else if (action.action_id === ACTION_DECLINE) {
      if (!refiner.decline(threadTs)) return;
      draftCards.delete(messageTs);
      await retireCard(messageTs, summary, ':wave: Cancelled — no ticket created.');
    }
  }

  // Replace a card's buttons with a read-only footer so it can't be clicked again.
  async function retireCard(messageTs, summary, footer) {
    if (!messageTs) return;
    await slack.updateMessage(channelId, messageTs, footer, resolvedBlocks(summary, footer))
      .catch((err) => console.error(`[slack-listener] updateMessage failed: ${err.message}`));
  }

  async function createTicket(channelId, threadTs, draft, messageTs, summary) {
    try {
      const issue = await linear.createIssue({
        title: draft.title,
        description: draft.description,
        priority: draft.priority,
      });
      refiner.markDone(threadTs);
      await retireCard(messageTs, summary, `:white_check_mark: *${issue.identifier}* created: ${issue.url}`);
      await slack.replyInThread(
        channelId,
        threadTs,
        `:white_check_mark: *${issue.identifier}* created: ${issue.url}`,
      );
      console.log(`[slack-listener] created ${issue.identifier} ${issue.url}`);
    } catch (err) {
      console.error('[slack-listener] Linear error:', err.message);
      await retireCard(messageTs, summary, `:x: Failed to create ticket: ${err.message}`);
      await slack.replyInThread(
        channelId,
        threadTs,
        `:x: Failed to create ticket: ${err.message}`,
      );
    }
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
