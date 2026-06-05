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
    it('new tickets are Unclaimed', () => {
      assert.equal(store.getState('ENG-1'), 'Unclaimed');
    });

    it('new tickets are not owned', () => {
      assert.equal(store.isOwned('ENG-1'), false);
    });
  });

  describe('acquire', () => {
    it('Unclaimed -> Running: acquire returns true', () => {
      const result = store.acquire('ENG-1', 'engine');
      assert.equal(result, true);
    });

    it('after acquire, ticket state is Running', () => {
      store.acquire('ENG-1', 'engine');
      assert.equal(store.getState('ENG-1'), 'Running');
    });

    it('after acquire, ticket is owned', () => {
      store.acquire('ENG-1', 'engine');
      assert.equal(store.isOwned('ENG-1'), true);
    });

    it('double-acquire by same conceptual owner is rejected (ticket already Running)', () => {
      store.acquire('ENG-1', 'engine');
      const second = store.acquire('ENG-1', 'engine');
      assert.equal(second, false);
    });

    it('double-acquire by different owner is also rejected', () => {
      store.acquire('ENG-1', 'engine-1');
      const second = store.acquire('ENG-1', 'engine-2');
      assert.equal(second, false);
    });

    it('acquire on RetryQueued ticket is rejected', () => {
      store.acquire('ENG-1', 'engine');
      store.queueRetry('ENG-1', Date.now() + 10000);
      const result = store.acquire('ENG-1', 'engine');
      assert.equal(result, false);
    });

    it('acquiring different tickets is independent', () => {
      const r1 = store.acquire('ENG-1', 'engine');
      const r2 = store.acquire('ENG-2', 'engine');
      assert.equal(r1, true);
      assert.equal(r2, true);
    });
  });

  describe('release', () => {
    it('Running -> Unclaimed: release transitions state back', () => {
      store.acquire('ENG-1', 'engine');
      store.release('ENG-1', 'engine');
      assert.equal(store.getState('ENG-1'), 'Unclaimed');
    });

    it('after release, ticket is no longer owned', () => {
      store.acquire('ENG-1', 'engine');
      store.release('ENG-1', 'engine');
      assert.equal(store.isOwned('ENG-1'), false);
    });

    it('release-not-owned is a no-op (no throw)', () => {
      assert.doesNotThrow(() => store.release('ENG-99', 'engine'));
      assert.equal(store.getState('ENG-99'), 'Unclaimed');
    });

    it('release by wrong owner is a no-op (no throw)', () => {
      store.acquire('ENG-1', 'engine-1');
      assert.doesNotThrow(() => store.release('ENG-1', 'engine-2'));
      assert.equal(store.getState('ENG-1'), 'Running');
    });

    it('ticket can be re-acquired after release', () => {
      store.acquire('ENG-1', 'engine');
      store.release('ENG-1', 'engine');
      const result = store.acquire('ENG-1', 'engine');
      assert.equal(result, true);
    });
  });

  describe('queueRetry', () => {
    it('Running -> RetryQueued: transitions state', () => {
      store.acquire('ENG-1', 'engine');
      store.queueRetry('ENG-1', Date.now() + 60000);
      assert.equal(store.getState('ENG-1'), 'RetryQueued');
    });

    it('RetryQueued ticket is still owned (isOwned returns true)', () => {
      store.acquire('ENG-1', 'engine');
      store.queueRetry('ENG-1', Date.now() + 60000);
      assert.equal(store.isOwned('ENG-1'), true);
    });

    it('queueRetry on Unclaimed ticket is a no-op', () => {
      assert.doesNotThrow(() => store.queueRetry('ENG-99', Date.now() + 60000));
      assert.equal(store.getState('ENG-99'), 'Unclaimed');
    });

    it('queueRetry on already-RetryQueued ticket is a no-op', () => {
      store.acquire('ENG-1', 'engine');
      const retryAt1 = Date.now() + 60000;
      store.queueRetry('ENG-1', retryAt1);
      const retryAt2 = Date.now() + 120000;
      store.queueRetry('ENG-1', retryAt2);
      assert.equal(store.getState('ENG-1'), 'RetryQueued');
    });
  });
});
