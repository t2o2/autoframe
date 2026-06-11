/**
 * slack-client.js — thin fetch-based Slack Web API wrapper (polling, no Socket Mode).
 */

export class SlackClient {
  constructor(token) {
    this.token = token;
  }

  async call(method, body) {
    const res = await fetch(`https://slack.com/api/${method}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.token}`,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!data.ok) {
      const detail = data.response_metadata?.messages?.join('; ');
      throw new Error(`Slack ${method}: ${data.error}${detail ? ` (${detail})` : ''}`);
    }
    return data;
  }

  /** GET-style call — sends params as URL query string (for methods like conversations.replies). */
  async get(method, params) {
    const qs = new URLSearchParams(
      Object.entries(params).filter(([, v]) => v != null).map(([k, v]) => [k, String(v)])
    ).toString();
    const res = await fetch(`https://slack.com/api/${method}?${qs}`, {
      headers: { Authorization: `Bearer ${this.token}` },
    });
    const data = await res.json();
    if (!data.ok) {
      const detail = data.response_metadata?.messages?.join('; ');
      throw new Error(`Slack ${method}: ${data.error}${detail ? ` (${detail})` : ''}`);
    }
    return data;
  }

  async getBotUserId() {
    const data = await this.call('auth.test', {});
    return data.user_id;
  }

  /** Resolve channel name (#foo) or ID (Cxxx) to a definitive channel ID. */
  async resolveChannelId(channelOrId) {
    if (/^[CG][A-Z0-9]{6,}/i.test(channelOrId)) return channelOrId;
    const name = channelOrId.replace(/^#/, '');
    let cursor;
    do {
      const data = await this.call('conversations.list', {
        types: 'public_channel,private_channel',
        limit: 200,
        cursor,
      });
      const ch = (data.channels ?? []).find((c) => c.name === name);
      if (ch) return ch.id;
      cursor = data.response_metadata?.next_cursor;
    } while (cursor);
    throw new Error(`Slack channel not found: ${channelOrId}`);
  }

  /** Fetch new root messages in a channel after `oldest` (unix float string). */
  async getChannelHistory(channelId, { oldest } = {}) {
    const body = { channel: channelId, limit: 50 };
    if (oldest) body.oldest = oldest;
    return this.call('conversations.history', body);
  }

  /** Fetch messages in a thread after `oldest` (unix float string). */
  async getThreadReplies(channelId, threadTs, oldest) {
    return this.get('conversations.replies', {
      channel: channelId,
      ts: threadTs,
      limit: 100,
      oldest: oldest || undefined,
    });
  }

  async postMessage(channelId, text) {
    return this.call('chat.postMessage', { channel: channelId, text, unfurl_links: false });
  }

  async replyInThread(channelId, threadTs, text) {
    return this.call('chat.postMessage', {
      channel: channelId,
      thread_ts: threadTs,
      text,
      unfurl_links: false,
    });
  }

  /** Add an emoji reaction to a message. Requires reactions:write scope. */
  async addReaction(channelId, ts, emoji = 'eyes') {
    return this.call('reactions.add', { channel: channelId, timestamp: ts, name: emoji });
  }

  /** Remove an emoji reaction from a message. Requires reactions:write scope. */
  async removeReaction(channelId, ts, emoji = 'eyes') {
    return this.call('reactions.remove', { channel: channelId, timestamp: ts, name: emoji });
  }
}
