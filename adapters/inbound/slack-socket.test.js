import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { handleFrame, backoffDelay, SlackSocket } from './slack-socket.js';

describe('handleFrame', () => {
  it('reports a hello frame without acking', async () => {
    let acked = false;
    const r = await handleFrame({ type: 'hello' }, { ack: () => { acked = true; }, onBlockAction: () => {} });
    assert.equal(r, 'hello');
    assert.equal(acked, false);
  });

  it('reports a disconnect frame so the caller can reconnect', async () => {
    const r = await handleFrame({ type: 'disconnect', reason: 'refresh' }, { ack: () => {}, onBlockAction: () => {} });
    assert.equal(r, 'disconnect');
  });

  it('acks and dispatches block_actions interactivity payloads', async () => {
    const acks = [];
    const actions = [];
    const frame = {
      type: 'interactive',
      envelope_id: 'env-1',
      payload: { type: 'block_actions', actions: [{ action_id: 'ticket_approve', value: 't1' }] },
    };
    const r = await handleFrame(frame, {
      ack: (id) => acks.push(id),
      onBlockAction: (p) => actions.push(p),
    });
    assert.equal(r, 'block_actions');
    assert.deepEqual(acks, ['env-1']);
    assert.equal(actions[0].actions[0].action_id, 'ticket_approve');
  });

  it('acks-only for non-block_actions envelopes', async () => {
    const acks = [];
    const r = await handleFrame(
      { type: 'interactive', envelope_id: 'env-2', payload: { type: 'view_submission' } },
      { ack: (id) => acks.push(id), onBlockAction: () => { throw new Error('should not dispatch'); } },
    );
    assert.equal(r, 'ack-only');
    assert.deepEqual(acks, ['env-2']);
  });

  it('ignores malformed frames', async () => {
    assert.equal(await handleFrame(null, { ack: () => {}, onBlockAction: () => {} }), 'ignored');
  });
});

describe('backoffDelay', () => {
  it('grows exponentially from the base', () => {
    const opts = { baseMs: 1_000, maxMs: 30_000 };
    assert.equal(backoffDelay(1, opts), 1_000);
    assert.equal(backoffDelay(2, opts), 2_000);
    assert.equal(backoffDelay(3, opts), 4_000);
    assert.equal(backoffDelay(4, opts), 8_000);
  });

  it('is capped at maxMs', () => {
    const opts = { baseMs: 1_000, maxMs: 5_000 };
    assert.equal(backoffDelay(10, opts), 5_000);
    assert.equal(backoffDelay(100, opts), 5_000);
  });

  it('treats sub-1 attempts as attempt 1', () => {
    assert.equal(backoffDelay(0, { baseMs: 250, maxMs: 9_000 }), 250);
  });
});

// A controllable timer queue so reconnect scheduling can be stepped
// deterministically without real timers.
function makeScheduler() {
  let timers = [];
  const setT = (fn) => {
    const t = { fn, cancelled: false };
    timers.push(t);
    return t;
  };
  const clearT = (t) => { if (t) t.cancelled = true; };
  const pending = () => timers.filter((t) => !t.cancelled);
  // Fire the currently-queued (uncancelled) timers once, flushing the
  // microtasks each callback spawns (so async reconnect rejections resolve).
  const flush = async () => {
    const batch = timers;
    timers = [];
    for (const t of batch) {
      if (t.cancelled) continue;
      t.fn();
      await Promise.resolve();
      await Promise.resolve();
    }
  };
  return { setT, clearT, pending, flush };
}

describe('SlackSocket reconnect resilience', () => {
  it('keeps retrying after a failed reconnect instead of giving up', async () => {
    let fetchCalls = 0;
    const fetchImpl = async () => {
      fetchCalls += 1;
      throw Object.assign(new Error('fetch failed'), { cause: { code: 'ECONNRESET' } });
    };
    const sched = makeScheduler();
    const socket = new SlackSocket('xapp-test', {
      fetchImpl,
      // _openConnectionUrl fails before a socket is ever constructed.
      WebSocketImpl: class { addEventListener() {} },
      setTimeoutImpl: sched.setT,
      clearTimeoutImpl: sched.clearT,
      reconnect: { baseMs: 1, maxMs: 4 },
    });

    socket._scheduleReconnect();
    assert.equal(sched.pending().length, 1, 'first attempt scheduled');

    await sched.flush(); // attempt #1 fails -> must reschedule
    assert.equal(fetchCalls, 1);
    assert.equal(sched.pending().length, 1, 'rescheduled after failure (the bug fix)');

    await sched.flush(); // attempt #2 fails -> reschedules again
    assert.equal(fetchCalls, 2);
    assert.equal(sched.pending().length, 1, 'still retrying');

    await sched.flush(); // attempt #3
    assert.equal(fetchCalls, 3);
  });

  it('stop() halts the reconnect loop and cancels the pending timer', async () => {
    let fetchCalls = 0;
    const fetchImpl = async () => {
      fetchCalls += 1;
      throw new Error('fetch failed');
    };
    const sched = makeScheduler();
    const socket = new SlackSocket('xapp-test', {
      fetchImpl,
      WebSocketImpl: class { addEventListener() {} },
      setTimeoutImpl: sched.setT,
      clearTimeoutImpl: sched.clearT,
      reconnect: { baseMs: 1, maxMs: 4 },
    });

    socket._scheduleReconnect();
    await sched.flush(); // one failed attempt, reschedules
    assert.equal(fetchCalls, 1);
    assert.equal(sched.pending().length, 1);

    socket.stop();
    assert.equal(sched.pending().length, 0, 'pending timer cancelled by stop()');

    await sched.flush();
    assert.equal(fetchCalls, 1, 'no further attempts after stop()');

    // A late close/error signal must not revive the loop.
    socket._scheduleReconnect();
    await sched.flush();
    assert.equal(fetchCalls, 1, '_scheduleReconnect is a no-op once stopped');
  });

  it('does not stack duplicate timers when scheduled twice', () => {
    const sched = makeScheduler();
    const socket = new SlackSocket('xapp-test', {
      fetchImpl: async () => { throw new Error('fetch failed'); },
      WebSocketImpl: class { addEventListener() {} },
      setTimeoutImpl: sched.setT,
      clearTimeoutImpl: sched.clearT,
      reconnect: { baseMs: 1, maxMs: 4 },
    });

    socket._scheduleReconnect();
    socket._scheduleReconnect(); // overlapping close+error signals
    assert.equal(sched.pending().length, 1, 'only one timer in flight');
  });
});
