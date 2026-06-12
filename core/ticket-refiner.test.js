import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { TicketRefiner, renderDraftSummary } from './ticket-refiner.js';

/**
 * Fake ClaudeChat that returns scripted assistant turns in order, so we can
 * drive the refiner state machine deterministically without the network.
 */
class FakeClaude {
  constructor(replies) {
    this.replies = [...replies];
    this.calls = [];
  }
  async chat(messages, systemPrompt) {
    this.calls.push({ messages: structuredClone(messages), systemPrompt });
    return this.replies.shift() ?? '';
  }
}

const DRAFT_JSON = '```json\n{"action":"create_ticket","title":"Fix login","description":"Users cannot log in.","priority":2}\n```';

describe('TicketRefiner.processMessage', () => {
  it('returns a plain reply while still gathering information', async () => {
    const claude = new FakeClaude(['What is the expected behavior?']);
    const refiner = new TicketRefiner(claude);

    const result = await refiner.processMessage('t1', 'login is broken');

    assert.deepEqual(result, { type: 'reply', text: 'What is the expected behavior?' });
    assert.equal(refiner.get('t1').status, 'refining');
  });

  it('returns a draft (not an auto-create) when Claude emits the ticket JSON', async () => {
    const claude = new FakeClaude([DRAFT_JSON]);
    const refiner = new TicketRefiner(claude);

    const result = await refiner.processMessage('t1', 'login is broken, fix it');

    assert.equal(result.type, 'draft');
    assert.equal(result.draft.title, 'Fix login');
    assert.equal(result.draft.priority, 2);
    assert.equal(refiner.get('t1').status, 'awaiting_approval');
  });

  it('normalizes a string priority to its numeric code', async () => {
    const json = '```json\n{"action":"create_ticket","title":"X","description":"Y","priority":"High"}\n```';
    const claude = new FakeClaude([json]);
    const refiner = new TicketRefiner(claude);

    const result = await refiner.processMessage('t1', 'do it');

    assert.equal(result.draft.priority, 2);
  });

  it('treats a follow-up message after a draft as a revision (back to refining)', async () => {
    const claude = new FakeClaude([DRAFT_JSON, 'Updated the title. Anything else?']);
    const refiner = new TicketRefiner(claude);

    await refiner.processMessage('t1', 'login broken');
    const result = await refiner.processMessage('t1', 'actually call it Sign-in outage');

    assert.deepEqual(result, { type: 'reply', text: 'Updated the title. Anything else?' });
    assert.equal(refiner.get('t1').status, 'refining');
  });

  it('returns cancelled when Claude signals cancellation in text', async () => {
    const claude = new FakeClaude(['Got it, cancelled.']);
    const refiner = new TicketRefiner(claude);

    const result = await refiner.processMessage('t1', 'cancel');

    assert.deepEqual(result, { type: 'cancelled' });
    assert.equal(refiner.get('t1').status, 'cancelled');
  });

  it('ignores messages once the conversation is creating/done/cancelled', async () => {
    const claude = new FakeClaude([DRAFT_JSON]);
    const refiner = new TicketRefiner(claude);
    await refiner.processMessage('t1', 'login broken');
    refiner.approve('t1');

    const result = await refiner.processMessage('t1', 'wait stop');

    assert.equal(result, null);
  });
});

describe('TicketRefiner.approve', () => {
  it('returns the stored draft and moves to creating', async () => {
    const claude = new FakeClaude([DRAFT_JSON]);
    const refiner = new TicketRefiner(claude);
    await refiner.processMessage('t1', 'login broken');

    const draft = refiner.approve('t1');

    assert.equal(draft.title, 'Fix login');
    assert.equal(refiner.get('t1').status, 'creating');
  });

  it('returns null when there is no draft awaiting approval', () => {
    const refiner = new TicketRefiner(new FakeClaude([]));
    assert.equal(refiner.approve('missing'), null);
  });

  it('returns null on a second approval (idempotent guard against double clicks)', async () => {
    const claude = new FakeClaude([DRAFT_JSON]);
    const refiner = new TicketRefiner(claude);
    await refiner.processMessage('t1', 'login broken');

    assert.ok(refiner.approve('t1'));
    assert.equal(refiner.approve('t1'), null);
  });
});

describe('TicketRefiner.decline', () => {
  it('marks the conversation cancelled', async () => {
    const claude = new FakeClaude([DRAFT_JSON]);
    const refiner = new TicketRefiner(claude);
    await refiner.processMessage('t1', 'login broken');

    const ok = refiner.decline('t1');

    assert.equal(ok, true);
    assert.equal(refiner.get('t1').status, 'cancelled');
  });

  it('returns false when there is nothing to decline', () => {
    const refiner = new TicketRefiner(new FakeClaude([]));
    assert.equal(refiner.decline('missing'), false);
  });
});

describe('renderDraftSummary', () => {
  it('renders title, priority label and description for the approval card', () => {
    const summary = renderDraftSummary({ title: 'Fix login', description: 'Users cannot log in.', priority: 2 });
    assert.match(summary, /Fix login/);
    assert.match(summary, /High/);
    assert.match(summary, /Users cannot log in\./);
  });

  it('falls back to Medium for an unknown priority code', () => {
    const summary = renderDraftSummary({ title: 'X', description: 'Y', priority: 99 });
    assert.match(summary, /Medium/);
  });
});
