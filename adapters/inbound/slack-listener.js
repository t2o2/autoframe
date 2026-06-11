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
import { TicketRefiner } from '../../core/ticket-refiner.js';

const POLL_INTERVAL_MS = 5_000;

/**
 * Start the polling loop. Never resolves (runs until process exits).
 *
 * @param {{
 *   slackToken: string,
 *   ticketChannel: string,
 *   anthropicApiKey: string,
 *   linearApiKey: string,
 *   linearTeamKey: string,
 *   pollIntervalMs?: number,
 * }} opts
 */
export async function startSlackListener({
  slackToken,
  ticketChannel,
  anthropicApiKey,
  linearApiKey,
  linearTeamKey,
  pollIntervalMs = POLL_INTERVAL_MS,
}) {
  const slack = new SlackClient(slackToken);
  const linear = new LinearIssueCreator(linearApiKey, linearTeamKey);
  const claude = new ClaudeChat(anthropicApiKey);
  const refiner = new TicketRefiner(claude);

  const channelId = await slack.resolveChannelId(ticketChannel);
  console.log(`[slack-listener] channel=${ticketChannel} (${channelId}) poll=${pollIntervalMs}ms`);

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

      const data = await slack.getThreadReplies(channelId, threadTs);
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
    await slack.addReaction(channelId, threadTs).catch(() => {});
    await runTurn(channelId, threadTs, userText);
  }

  async function onThreadReply(channelId, threadTs, replyTs, userText) {
    console.log(`[slack-listener] thread reply thread=${threadTs} text="${userText.slice(0, 80)}"`);
    await slack.addReaction(channelId, replyTs).catch(() => {});
    await runTurn(channelId, threadTs, userText);
  }

  async function runTurn(channelId, threadTs, userText) {
    let result;
    try {
      result = await refiner.processMessage(threadTs, userText);
    } catch (err) {
      console.error('[slack-listener] Claude error:', err.message);
      await slack.replyInThread(channelId, threadTs, `:x: Claude error: ${err.message}`);
      return;
    }

    if (!result) return;

    if (result.type === 'reply') {
      await slack.replyInThread(channelId, threadTs, result.text);
    } else if (result.type === 'cancelled') {
      await slack.replyInThread(channelId, threadTs, ':wave: Ticket creation cancelled.');
    } else if (result.type === 'create_ticket') {
      await createTicket(channelId, threadTs, result.draft);
    }
  }

  async function createTicket(channelId, threadTs, draft) {
    await slack.replyInThread(channelId, threadTs, ':hourglass_flowing_sand: Creating ticket…');
    try {
      const issue = await linear.createIssue({
        title: draft.title,
        description: draft.description,
        priority: draft.priority,
      });
      refiner.markDone(threadTs);
      await slack.replyInThread(
        channelId,
        threadTs,
        `:white_check_mark: *${issue.identifier}* created: ${issue.url}`,
      );
      console.log(`[slack-listener] created ${issue.identifier} ${issue.url}`);
    } catch (err) {
      console.error('[slack-listener] Linear error:', err.message);
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
