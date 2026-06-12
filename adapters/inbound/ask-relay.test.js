import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createAskRelay } from './ask-relay.js';
import { encodeAskValue, optsKey, ansKey } from './ask-buttons.js';

class FakeRedis {
  constructor(seed = {}) { this.store = new Map(Object.entries(seed)); this.sets = []; }
  async get(k) { return this.store.has(k) ? this.store.get(k) : null; }
  async set(k, v, ...rest) { this.store.set(k, v); this.sets.push({ k, v, rest }); }
}

class FakeSlack {
  constructor() { this.updates = []; }
  async updateMessage(channel, ts, text, blocks) { this.updates.push({ channel, ts, text, blocks }); }
}

function payload(key, idx) {
  return {
    actions: [{ action_id: `ask_human_${idx}`, value: encodeAskValue(key, idx) }],
    container: { channel_id: 'C1', message_ts: '111.1' },
    message: { blocks: [{ type: 'section', text: { type: 'mrkdwn', text: '*ENG-1* — pick one' } }] },
  };
}

describe('createAskRelay', () => {
  it('writes the resolved option label to the answer key', async () => {
    const redis = new FakeRedis({ [optsKey('k1')]: JSON.stringify(['Postgres', 'Redis']) });
    const slack = new FakeSlack();
    const relay = createAskRelay({ redis, slack });

    await relay(payload('k1', 1));

    assert.equal(await redis.get(ansKey('k1')), 'Redis');
    assert.equal(redis.sets[0].rest[0], 'EX'); // TTL applied
  });

  it('writes an empty answer on skip so the asker still unblocks', async () => {
    const redis = new FakeRedis({ [optsKey('k1')]: JSON.stringify(['Postgres', 'Redis']) });
    const slack = new FakeSlack();
    const relay = createAskRelay({ redis, slack });

    await relay(payload('k1', 'skip'));

    assert.equal(await redis.get(ansKey('k1')), '');
  });

  it('retires the card with a read-only footer reflecting the choice', async () => {
    const redis = new FakeRedis({ [optsKey('k1')]: JSON.stringify(['Postgres', 'Redis']) });
    const slack = new FakeSlack();
    const relay = createAskRelay({ redis, slack });

    await relay(payload('k1', 0));

    assert.equal(slack.updates.length, 1);
    assert.match(slack.updates[0].text, /Postgres/);
    assert.ok(!slack.updates[0].blocks.some((b) => b.type === 'actions'), 'no buttons remain');
  });

  it('ignores payloads with an unparseable value', async () => {
    const redis = new FakeRedis();
    const slack = new FakeSlack();
    const relay = createAskRelay({ redis, slack });

    await relay({ actions: [{ value: 'garbage' }], container: {} });

    assert.equal(redis.sets.length, 0);
    assert.equal(slack.updates.length, 0);
  });
});
