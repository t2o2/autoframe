import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRedisClaimStore } from './claim-store-redis.js';

/**
 * Minimal in-memory fake of the ioredis surface the claim store uses.
 * `eval` faithfully re-implements RELEASE_SCRIPT (delete only if the stored
 * value's JSON .owner matches ARGV[1]) so the JSON value format is exercised
 * here even though Lua can't run in-process.
 */
function makeFakeRedis() {
  const data = new Map();
  return {
    _data: data,
    on() {},
    async set(key, value, ...opts) {
      const hasNx = opts.includes('NX');
      if (hasNx && data.has(key)) return null;
      data.set(key, value);
      return 'OK';
    },
    async get(key) {
      return data.has(key) ? data.get(key) : null;
    },
    async del(key) {
      return data.delete(key) ? 1 : 0;
    },
    async exists(key) {
      return data.has(key) ? 1 : 0;
    },
    async eval(_script, _numKeys, key, owner, ts, _ttl) {
      const v = data.has(key) ? data.get(key) : null;
      if (v === null) return 0;
      // Heartbeat script: ts arg present — update lastHeartbeat in place
      if (ts !== undefined) {
        try {
          const decoded = JSON.parse(v);
          if (decoded.owner !== owner) return 0;
          decoded.lastHeartbeat = Number(ts);
          data.set(key, JSON.stringify(decoded));
          return 1;
        } catch { return 0; }
      }
      // Release script: delete only if owner matches
      try {
        const decoded = JSON.parse(v);
        if (decoded.owner === owner) {
          data.delete(key);
          return 1;
        }
      } catch {
        // non-JSON value (e.g. retry marker) — not owned, no-op
      }
      return 0;
    },
    async scan(cursor, _match, pattern, _count, _n) {
      // Single-pass scan: return all matching keys, cursor '0' (done).
      const prefix = pattern.replace(/\*$/, '');
      const keys = [...data.keys()].filter((k) => k.startsWith(prefix));
      return ['0', keys];
    },
    async quit() {},
  };
}

describe('createRedisClaimStore', () => {
  /** @type {ReturnType<typeof makeFakeRedis>} */
  let client;
  /** @type {ReturnType<typeof createRedisClaimStore>} */
  let store;
  let nowMs;

  beforeEach(() => {
    client = makeFakeRedis();
    nowMs = 1000;
    store = createRedisClaimStore({ client, clock: { now: () => nowMs } });
  });

  describe('acquire / isOwned / release', () => {
    it('acquires an unclaimed ticket', async () => {
      assert.equal(await store.acquire('ENG-1', 'engine', 'process', 1800), true);
      assert.equal(await store.isOwned('ENG-1', 'process'), true);
    });

    it('rejects a second acquire (NX)', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      assert.equal(await store.acquire('ENG-1', 'engine', 'process', 1800), false);
    });

    it('namespaces claims by stage', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      assert.equal(await store.isOwned('ENG-1', 'review'), false);
    });

    it('release by the owner frees the ticket', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      await store.release('ENG-1', 'engine', 'process');
      assert.equal(await store.isOwned('ENG-1', 'process'), false);
    });

    it('release by a different owner is a no-op (claim survives)', async () => {
      await store.acquire('ENG-1', 'engine-1', 'process', 1800);
      await store.release('ENG-1', 'engine-2', 'process');
      assert.equal(await store.isOwned('ENG-1', 'process'), true);
    });
  });

  describe('listRunning', () => {
    it('returns running tickets for the stage with startedAt and owner', async () => {
      nowMs = 5000;
      await store.acquire('ENG-1', 'container-a', 'process', 1800);
      const running = await store.listRunning('process');
      assert.equal(running.length, 1);
      assert.equal(running[0].ticketId, 'ENG-1');
      assert.equal(running[0].startedAt, 5000);
      assert.equal(running[0].owner, 'container-a');
    });

    it('only returns tickets for the requested stage', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      await store.acquire('ENG-2', 'engine', 'review', 1800);
      const running = await store.listRunning('process');
      assert.deepEqual(running.map((r) => r.ticketId), ['ENG-1']);
    });

    it('excludes retry-queued claims (non-JSON values)', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      await store.queueRetry('ENG-1', nowMs + 60000, 'process');
      assert.deepEqual(await store.listRunning('process'), []);
    });

    it('includes lastHeartbeat in the record after a heartbeat', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      await store.heartbeat('ENG-1', 'engine', 'process', 4242, 1800);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, 4242);
    });

    it('omits lastHeartbeat when no heartbeat has been sent', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, undefined);
    });
  });

  describe('heartbeat', () => {
    it('updates lastHeartbeat in the claim value when owner matches', async () => {
      await store.acquire('ENG-1', 'engine', 'process', 1800);
      await store.heartbeat('ENG-1', 'engine', 'process', 5000, 1800);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, 5000);
    });

    it('is a no-op when the owner does not match', async () => {
      await store.acquire('ENG-1', 'engine-a', 'process', 1800);
      await store.heartbeat('ENG-1', 'engine-b', 'process', 9999, 1800);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, undefined);
    });

    it('is a no-op when there is no claim', async () => {
      await assert.doesNotReject(() => store.heartbeat('ENG-1', 'engine', 'process', 9999, 1800));
      assert.deepEqual(await store.listRunning('process'), []);
    });
  });
});
