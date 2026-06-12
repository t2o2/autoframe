import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { handleFrame } from './slack-socket.js';

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
