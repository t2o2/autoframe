import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createClaimStore } from './claim.js';

describe('createClaimStore', () => {
  /** @type {ReturnType<typeof createClaimStore>} */
  let store;

  beforeEach(() => {
    store = createClaimStore();
  });

  describe('initial state', () => {
    it('new tickets are Unclaimed', async () => {
      assert.equal(await store.getState('ENG-1'), 'Unclaimed');
    });

    it('new tickets are not owned', async () => {
      assert.equal(await store.isOwned('ENG-1'), false);
    });
  });

  describe('acquire', () => {
    it('Unclaimed -> Running: acquire returns true', async () => {
      const result = await store.acquire('ENG-1', 'engine');
      assert.equal(result, true);
    });

    it('after acquire, ticket state is Running', async () => {
      await store.acquire('ENG-1', 'engine');
      assert.equal(await store.getState('ENG-1'), 'Running');
    });

    it('after acquire, ticket is owned', async () => {
      await store.acquire('ENG-1', 'engine');
      assert.equal(await store.isOwned('ENG-1'), true);
    });

    it('double-acquire by same conceptual owner is rejected (ticket already Running)', async () => {
      await store.acquire('ENG-1', 'engine');
      const second = await store.acquire('ENG-1', 'engine');
      assert.equal(second, false);
    });

    it('double-acquire by different owner is also rejected', async () => {
      await store.acquire('ENG-1', 'engine-1');
      const second = await store.acquire('ENG-1', 'engine-2');
      assert.equal(second, false);
    });

    it('acquire on RetryQueued ticket is rejected', async () => {
      await store.acquire('ENG-1', 'engine');
      await store.queueRetry('ENG-1', Date.now() + 10000);
      const result = await store.acquire('ENG-1', 'engine');
      assert.equal(result, false);
    });

    it('acquiring different tickets is independent', async () => {
      const r1 = await store.acquire('ENG-1', 'engine');
      const r2 = await store.acquire('ENG-2', 'engine');
      assert.equal(r1, true);
      assert.equal(r2, true);
    });
  });

  describe('release', () => {
    it('Running -> Unclaimed: release transitions state back', async () => {
      await store.acquire('ENG-1', 'engine');
      await store.release('ENG-1', 'engine');
      assert.equal(await store.getState('ENG-1'), 'Unclaimed');
    });

    it('after release, ticket is no longer owned', async () => {
      await store.acquire('ENG-1', 'engine');
      await store.release('ENG-1', 'engine');
      assert.equal(await store.isOwned('ENG-1'), false);
    });

    it('release-not-owned is a no-op (no throw)', async () => {
      await assert.doesNotReject(() => store.release('ENG-99', 'engine'));
      assert.equal(await store.getState('ENG-99'), 'Unclaimed');
    });

    it('release by wrong owner is a no-op (no throw)', async () => {
      await store.acquire('ENG-1', 'engine-1');
      await assert.doesNotReject(() => store.release('ENG-1', 'engine-2'));
      assert.equal(await store.getState('ENG-1'), 'Running');
    });

    it('ticket can be re-acquired after release', async () => {
      await store.acquire('ENG-1', 'engine');
      await store.release('ENG-1', 'engine');
      const result = await store.acquire('ENG-1', 'engine');
      assert.equal(result, true);
    });
  });

  describe('queueRetry', () => {
    it('Running -> RetryQueued: transitions state', async () => {
      await store.acquire('ENG-1', 'engine');
      await store.queueRetry('ENG-1', Date.now() + 60000);
      assert.equal(await store.getState('ENG-1'), 'RetryQueued');
    });

    it('RetryQueued ticket is still owned (isOwned returns true)', async () => {
      await store.acquire('ENG-1', 'engine');
      await store.queueRetry('ENG-1', Date.now() + 60000);
      assert.equal(await store.isOwned('ENG-1'), true);
    });

    it('queueRetry on Unclaimed ticket is a no-op', async () => {
      await assert.doesNotReject(() => store.queueRetry('ENG-99', Date.now() + 60000));
      assert.equal(await store.getState('ENG-99'), 'Unclaimed');
    });

    it('queueRetry on already-RetryQueued ticket is a no-op', async () => {
      await store.acquire('ENG-1', 'engine');
      const retryAt1 = Date.now() + 60000;
      await store.queueRetry('ENG-1', retryAt1);
      const retryAt2 = Date.now() + 120000;
      await store.queueRetry('ENG-1', retryAt2);
      assert.equal(await store.getState('ENG-1'), 'RetryQueued');
    });
  });

  describe('listRunning', () => {
    it('returns empty array when nothing is running', async () => {
      assert.deepEqual(await store.listRunning('process'), []);
    });

    it('returns Running claims for the given stage with startedAt and owner', async () => {
      const clock = { now: () => 1000 };
      const s = createClaimStore({ clock });
      await s.acquire('ENG-1', 'container-a', 'process');

      const running = await s.listRunning('process');
      assert.equal(running.length, 1);
      assert.equal(running[0].ticketId, 'ENG-1');
      assert.equal(running[0].startedAt, 1000);
      assert.equal(running[0].owner, 'container-a');
    });

    it('namespaces by stage — a claim in one stage is not listed under another', async () => {
      await store.acquire('ENG-1', 'engine', 'process');
      assert.equal((await store.listRunning('process')).length, 1);
      assert.deepEqual(await store.listRunning('review'), []);
    });

    it('excludes RetryQueued claims', async () => {
      await store.acquire('ENG-1', 'engine', 'process');
      await store.queueRetry('ENG-1', Date.now() + 60000, 'process');
      assert.deepEqual(await store.listRunning('process'), []);
    });

    it('drops a released claim from the running list', async () => {
      await store.acquire('ENG-1', 'engine', 'process');
      await store.release('ENG-1', 'engine', 'process');
      assert.deepEqual(await store.listRunning('process'), []);
    });

    it('includes lastHeartbeat in the record after a heartbeat', async () => {
      await store.acquire('ENG-1', 'engine', 'process');
      await store.heartbeat('ENG-1', 'engine', 'process', 7777);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, 7777);
    });

    it('omits lastHeartbeat when no heartbeat has been sent', async () => {
      await store.acquire('ENG-1', 'engine', 'process');
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, undefined);
    });
  });

  describe('heartbeat', () => {
    it('updates lastHeartbeat on the held claim', async () => {
      await store.acquire('ENG-1', 'engine', 'process');
      await store.heartbeat('ENG-1', 'engine', 'process', 5000);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, 5000);
    });

    it('overwrites a previous heartbeat with the newer timestamp', async () => {
      await store.acquire('ENG-1', 'engine', 'process');
      await store.heartbeat('ENG-1', 'engine', 'process', 5000);
      await store.heartbeat('ENG-1', 'engine', 'process', 9000);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, 9000);
    });

    it('is a no-op when the owner does not match', async () => {
      await store.acquire('ENG-1', 'engine-a', 'process');
      await store.heartbeat('ENG-1', 'engine-b', 'process', 9999);
      const [record] = await store.listRunning('process');
      assert.equal(record.lastHeartbeat, undefined);
    });

    it('is a no-op when there is no claim', async () => {
      await assert.doesNotReject(() => store.heartbeat('ENG-1', 'engine', 'process', 9999));
      assert.deepEqual(await store.listRunning('process'), []);
    });
  });
});
