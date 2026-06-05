import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createScheduler } from './scheduler.js';
import { createClaimStore } from './claim.js';

/**
 * Build a minimal fake StorePort for tests.
 * running records live in an in-memory array per stage.
 * writeAttempt adds to the running list so _runningCount() is accurate within a tick.
 *
 * @param {Map<string, object[]>} initialRunning
 */
function makeStore(initialRunning = new Map()) {
  const running = new Map(initialRunning);
  return {
    writeHeartbeat() {},
    readHeartbeat() {
      return null;
    },
    writeAttempt(ticketId, stage, data) {
      const list = running.get(stage) ?? [];
      list.push(data);
      running.set(stage, list);
    },
    listRunning(stage) {
      return running.get(stage) ?? [];
    },
    _setRunning(stage, records) {
      running.set(stage, records);
    },
  };
}

/** @returns {import('./ports.js').StageConfig} */
function makeStage(overrides = {}) {
  return {
    name: 'process',
    poll: ['Plan Approved', 'Changes Required'],
    claim: 'In Progress',
    done: 'Review Pending',
    revert: 'Plan Approved',
    command: '/ticket-process',
    stale_threshold_s: 1800,
    linear_stale_threshold_s: 3600,
    ...overrides,
  };
}

/** @returns {import('./ports.js').Ticket} */
function makeTicket(overrides = {}) {
  return {
    id: 'ENG-1',
    priority: 2,
    createdAt: '2024-01-01T00:00:00.000Z',
    state: 'Plan Approved',
    ...overrides,
  };
}

describe('createScheduler', () => {
  /** @type {ReturnType<typeof createClaimStore>} */
  let claims;

  beforeEach(() => {
    claims = createClaimStore();
  });

  describe('stale ticket revert', () => {
    it('reverts a running ticket that has exceeded stale_threshold_s', async () => {
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - (THRESHOLD_S + 1) * 1000;

      const revertedTickets = [];
      const tracker = {
        async fetchCandidates() {
          return [];
        },
        async claimTicket() {},
        async revertTicket(ticketId) {
          revertedTickets.push(ticketId);
        },
        async getState() {
          return '';
        },
      };

      const stage = makeStage({ stale_threshold_s: THRESHOLD_S });

      const store = makeStore(
        new Map([['process', [{ ticketId: 'ENG-99', startedAt, stage: 'process' }]]]),
      );

      claims.acquire('ENG-99', 'engine');

      const clock = { now: () => now };

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims,
        store,
        clock,
        stages: [stage],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, ['ENG-99']);
      assert.equal(claims.isOwned('ENG-99'), false);
    });

    it('does not revert a running ticket within the stale threshold', async () => {
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - 60 * 1000;

      const revertedTickets = [];
      const tracker = {
        async fetchCandidates() {
          return [];
        },
        async claimTicket() {},
        async revertTicket(ticketId) {
          revertedTickets.push(ticketId);
        },
        async getState() {
          return '';
        },
      };

      const stage = makeStage({ stale_threshold_s: THRESHOLD_S });
      const store = makeStore(
        new Map([['process', [{ ticketId: 'ENG-99', startedAt, stage: 'process' }]]]),
      );

      claims.acquire('ENG-99', 'engine');

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims,
        store,
        clock: { now: () => now },
        stages: [stage],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, []);
      assert.equal(claims.isOwned('ENG-99'), true);
    });
  });

  describe('ticket dispatch', () => {
    it('claims and dispatches an unclaimed candidate ticket', async () => {
      const ticket = makeTicket();
      const dispatchedCommands = [];

      const tracker = {
        async fetchCandidates() {
          return [ticket];
        },
        async claimTicket() {},
        async revertTicket() {},
        async getState() {
          return '';
        },
      };

      const agentRuns = [];
      const agent = {
        async run(opts) {
          agentRuns.push(opts.command);
          return { exitCode: 0 };
        },
      };

      const scheduler = createScheduler({
        tracker,
        agent,
        claims,
        store: makeStore(),
        clock: { now: () => Date.now() },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      await new Promise((resolve) => setImmediate(resolve));

      assert.equal(agentRuns.length, 1);
      assert.equal(agentRuns[0], '/ticket-process ENG-1');
    });

    it('skips an already-claimed ticket', async () => {
      const ticket = makeTicket();

      claims.acquire(ticket.id, 'engine');

      const tracker = {
        async fetchCandidates() {
          return [ticket];
        },
        async claimTicket() {},
        async revertTicket() {},
        async getState() {
          return '';
        },
      };

      const agentRuns = [];
      const agent = {
        async run(opts) {
          agentRuns.push(opts.command);
          return { exitCode: 0 };
        },
      };

      const scheduler = createScheduler({
        tracker,
        agent,
        claims,
        store: makeStore(),
        clock: { now: () => Date.now() },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      await new Promise((resolve) => setImmediate(resolve));

      assert.equal(agentRuns.length, 0);
    });

    it('respects the concurrency cap', async () => {
      const tickets = [
        makeTicket({ id: 'ENG-1', priority: 1 }),
        makeTicket({ id: 'ENG-2', priority: 2 }),
        makeTicket({ id: 'ENG-3', priority: 3 }),
      ];

      const tracker = {
        async fetchCandidates() {
          return tickets;
        },
        async claimTicket() {},
        async revertTicket() {},
        async getState() {
          return '';
        },
      };

      const agentRuns = [];
      const agent = {
        run(opts) {
          agentRuns.push(opts.command);
          return new Promise(() => {});
        },
      };

      const scheduler = createScheduler({
        tracker,
        agent,
        claims,
        store: makeStore(),
        clock: { now: () => Date.now() },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      await new Promise((resolve) => setImmediate(resolve));

      assert.equal(agentRuns.length, 2);
    });
  });
});
