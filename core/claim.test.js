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
});
