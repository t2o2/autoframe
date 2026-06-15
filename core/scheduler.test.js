import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createScheduler } from './scheduler.js';
import { createClaimStore } from './claim.js';

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

      // Claim acquired in the past so listRunning reports an old startedAt.
      const staleClaims = createClaimStore({ clock: { now: () => startedAt } });
      await staleClaims.acquire('ENG-99', 'engine', 'process');

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

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: staleClaims,
        clock: { now: () => now },
        stages: [stage],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, ['ENG-99']);
      assert.equal(await staleClaims.isOwned('ENG-99', 'process'), false);
    });

    it('posts an explanatory comment when it reverts a stale ticket', async () => {
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - (THRESHOLD_S + 1) * 1000;

      const staleClaims = createClaimStore({ clock: { now: () => startedAt } });
      await staleClaims.acquire('ENG-99', 'worker-7', 'merge');

      const comments = [];
      const tracker = {
        async fetchCandidates() { return []; },
        async claimTicket() {},
        async revertTicket() {},
        async comment(ticketId, body) { comments.push({ ticketId, body }); },
        async getState() { return ''; },
      };

      const stage = makeStage({
        name: 'merge',
        stage_verb: 'merging',
        revert: 'Human Review',
        stale_threshold_s: THRESHOLD_S,
      });

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: staleClaims,
        clock: { now: () => now },
        stages: [stage],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.equal(comments.length, 1);
      assert.equal(comments[0].ticketId, 'ENG-99');
      assert.match(comments[0].body, /merging/);
      assert.match(comments[0].body, /Human Review/);
      assert.match(comments[0].body, /worker-7/);
    });

    it('still reverts a stale ticket when the tracker has no comment method', async () => {
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - (THRESHOLD_S + 1) * 1000;

      const staleClaims = createClaimStore({ clock: { now: () => startedAt } });
      await staleClaims.acquire('ENG-99', 'engine', 'process');

      const revertedTickets = [];
      const tracker = {
        async fetchCandidates() { return []; },
        async claimTicket() {},
        async revertTicket(ticketId) { revertedTickets.push(ticketId); },
        async getState() { return ''; },
        // no `comment` method — optional-chaining call must safely no-op
      };

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: staleClaims,
        clock: { now: () => now },
        stages: [makeStage({ stale_threshold_s: THRESHOLD_S })],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, ['ENG-99']);
      assert.equal(await staleClaims.isOwned('ENG-99', 'process'), false);
    });

    it('reverts even when posting the explanatory comment throws', async () => {
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - (THRESHOLD_S + 1) * 1000;

      const staleClaims = createClaimStore({ clock: { now: () => startedAt } });
      await staleClaims.acquire('ENG-99', 'engine', 'process');

      const revertedTickets = [];
      const tracker = {
        async fetchCandidates() { return []; },
        async claimTicket() {},
        async revertTicket(ticketId) { revertedTickets.push(ticketId); },
        async comment() { throw new Error('Linear API HTTP 500'); },
        async getState() { return ''; },
      };

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: staleClaims,
        clock: { now: () => now },
        stages: [makeStage({ stale_threshold_s: THRESHOLD_S })],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      // Comment failure must not block the revert or the release.
      assert.deepEqual(revertedTickets, ['ENG-99']);
      assert.equal(await staleClaims.isOwned('ENG-99', 'process'), false);
    });

    it('does not revert a running ticket within the stale threshold', async () => {
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - 60 * 1000;

      const freshClaims = createClaimStore({ clock: { now: () => startedAt } });
      await freshClaims.acquire('ENG-99', 'engine', 'process');

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

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: freshClaims,
        clock: { now: () => now },
        stages: [stage],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, []);
      assert.equal(await freshClaims.isOwned('ENG-99', 'process'), true);
    });

    it('does not revert when claim has a recent heartbeat, even past the claim age', async () => {
      // The claim was acquired long ago (would be stale by claim-age alone), but
      // the agent heartbeated 1 minute ago — it is alive, must NOT revert.
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - (THRESHOLD_S + 600) * 1000; // claimed 40 min ago

      const staleClaims = createClaimStore({ clock: { now: () => startedAt } });
      await staleClaims.acquire('ENG-99', 'engine', 'process');
      await staleClaims.heartbeat('ENG-99', 'engine', 'process', now - 60 * 1000); // 1 min ago

      const revertedTickets = [];
      const tracker = {
        async fetchCandidates() { return []; },
        async claimTicket() {},
        async revertTicket(ticketId) { revertedTickets.push(ticketId); },
        async getState() { return ''; },
      };

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: staleClaims,
        clock: { now: () => now },
        stages: [makeStage({ stale_threshold_s: THRESHOLD_S })],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, []);
      assert.equal(await staleClaims.isOwned('ENG-99', 'process'), true);
    });

    it('reverts when both startedAt and lastHeartbeat are stale', async () => {
      // Agent heartbeated, but the last heartbeat is also older than the threshold —
      // the agent is dead or hung; revert it.
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - (THRESHOLD_S + 600) * 1000; // 40 min ago

      const staleClaims = createClaimStore({ clock: { now: () => startedAt } });
      await staleClaims.acquire('ENG-99', 'engine', 'process');
      // Heartbeat also stale — more than threshold ago
      await staleClaims.heartbeat('ENG-99', 'engine', 'process', now - (THRESHOLD_S + 100) * 1000);

      const revertedTickets = [];
      const tracker = {
        async fetchCandidates() { return []; },
        async claimTicket() {},
        async revertTicket(ticketId) { revertedTickets.push(ticketId); },
        async getState() { return ''; },
      };

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: staleClaims,
        clock: { now: () => now },
        stages: [makeStage({ stale_threshold_s: THRESHOLD_S })],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, ['ENG-99']);
    });
  });

  describe('heartbeat wiring', () => {
    it('sends a heartbeat on the first onEvent call', async () => {
      const now = 2000000000000;
      const testClaims = createClaimStore({ clock: { now: () => now } });
      const ticket = makeTicket({ id: 'ENG-1' });

      let capturedOnEvent;
      const agent = {
        run({ onEvent }) {
          capturedOnEvent = onEvent;
          return new Promise(() => {}); // stays running
        },
      };

      const scheduler = createScheduler({
        tracker: {
          async fetchCandidates() { return [ticket]; },
          async claimTicket() {},
          async revertTicket() {},
          async getState() { return ''; },
        },
        agent,
        claims: testClaims,
        clock: { now: () => now },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 1 } },
      });

      await scheduler.tick();
      assert(capturedOnEvent !== undefined, 'onEvent should have been captured');

      capturedOnEvent({ kind: 'text', text: 'working' });
      await new Promise((resolve) => setImmediate(resolve));

      const [record] = await testClaims.listRunning('process');
      assert.equal(record.lastHeartbeat, now);
    });

    it('does not send a second heartbeat within the debounce interval', async () => {
      let now = 2000000000000;
      const testClaims = createClaimStore({ clock: { now: () => now } });
      const ticket = makeTicket({ id: 'ENG-1' });

      let capturedOnEvent;
      const agent = {
        run({ onEvent }) {
          capturedOnEvent = onEvent;
          return new Promise(() => {});
        },
      };

      const scheduler = createScheduler({
        tracker: {
          async fetchCandidates() { return [ticket]; },
          async claimTicket() {},
          async revertTicket() {},
          async getState() { return ''; },
        },
        agent,
        claims: testClaims,
        clock: { now: () => now },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 1 } },
      });

      await scheduler.tick();

      // First call at now — sets lastHeartbeat
      capturedOnEvent({ kind: 'text', text: 'a' });
      await new Promise((resolve) => setImmediate(resolve));

      // 5 seconds later — still inside debounce window (30s)
      now += 5000;
      capturedOnEvent({ kind: 'text', text: 'b' });
      await new Promise((resolve) => setImmediate(resolve));

      const [record] = await testClaims.listRunning('process');
      assert.equal(record.lastHeartbeat, 2000000000000); // unchanged — first value
    });

    it('sends a new heartbeat after the debounce interval has elapsed', async () => {
      let now = 2000000000000;
      const testClaims = createClaimStore({ clock: { now: () => now } });
      const ticket = makeTicket({ id: 'ENG-1' });

      let capturedOnEvent;
      const agent = {
        run({ onEvent }) {
          capturedOnEvent = onEvent;
          return new Promise(() => {});
        },
      };

      const scheduler = createScheduler({
        tracker: {
          async fetchCandidates() { return [ticket]; },
          async claimTicket() {},
          async revertTicket() {},
          async getState() { return ''; },
        },
        agent,
        claims: testClaims,
        clock: { now: () => now },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 1 } },
      });

      await scheduler.tick();

      capturedOnEvent({ kind: 'text', text: 'a' });
      await new Promise((resolve) => setImmediate(resolve));

      // Advance clock past debounce window (30s)
      now += 31_000;
      capturedOnEvent({ kind: 'text', text: 'b' });
      await new Promise((resolve) => setImmediate(resolve));

      const [record] = await testClaims.listRunning('process');
      assert.equal(record.lastHeartbeat, 2000000031000);
    });
  });

  describe('ticket dispatch', () => {
    it('claims and dispatches an unclaimed candidate ticket', async () => {
      const ticket = makeTicket();
      const agentRuns = [];

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
        clock: { now: () => Date.now() },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();
      await new Promise((resolve) => setImmediate(resolve));

      assert.equal(agentRuns.length, 1);
      assert.equal(agentRuns[0], '/ticket-process ENG-1');
    });

    it('releases the claim after the agent completes so the ticket can be re-processed', async () => {
      const ticket = makeTicket();

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

      const agent = {
        async run() {
          return { exitCode: 0 };
        },
      };

      const scheduler = createScheduler({
        tracker,
        agent,
        claims,
        clock: { now: () => Date.now() },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();
      await new Promise((resolve) => setImmediate(resolve));

      assert.equal(await claims.isOwned(ticket.id, 'process'), false);
    });

    it('skips an already-claimed ticket', async () => {
      const ticket = makeTicket();
      await claims.acquire(ticket.id, 'engine', 'process');

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
        clock: { now: () => Date.now() },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 2 } },
      });

      await scheduler.tick();
      await new Promise((resolve) => setImmediate(resolve));

      assert.equal(agentRuns.length, 0);
    });

    it('counts the concurrency cap per-container — another owner\'s claim does not consume a slot', async () => {
      // A different container is already running ENG-9 in this stage.
      await claims.acquire('ENG-9', 'other-container', 'process');

      const ticket = makeTicket({ id: 'ENG-1' });
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
        run(opts) {
          agentRuns.push(opts.command);
          return new Promise(() => {});
        },
      };

      const scheduler = createScheduler({
        tracker,
        agent,
        claims,
        clock: { now: () => Date.now() },
        stages: [makeStage()],
        config: { dispatch: { concurrency: 1 } },
        owner: 'me',
      });

      await scheduler.tick();
      await new Promise((resolve) => setImmediate(resolve));

      // Cap is 1 and another container holds a claim, but it's not mine — so I
      // still dispatch my one allowed agent. (A global cap would block here.)
      assert.equal(agentRuns.length, 1);
    });

    it('reverts and releases a stale claim held by another container', async () => {
      const THRESHOLD_S = 1800;
      const now = 2000000000000;
      const startedAt = now - (THRESHOLD_S + 1) * 1000;

      // A remote container acquired the claim long ago, then died.
      const staleClaims = createClaimStore({ clock: { now: () => startedAt } });
      await staleClaims.acquire('ENG-99', 'dead-container', 'process');

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

      const scheduler = createScheduler({
        tracker,
        agent: { async run() {} },
        claims: staleClaims,
        clock: { now: () => now },
        stages: [makeStage({ stale_threshold_s: THRESHOLD_S })],
        config: { dispatch: { concurrency: 2 } },
        owner: 'me',
      });

      await scheduler.tick();

      assert.deepEqual(revertedTickets, ['ENG-99']);
      assert.equal(await staleClaims.isOwned('ENG-99', 'process'), false);
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
