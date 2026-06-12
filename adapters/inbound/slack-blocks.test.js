import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { approvalBlocks, resolvedBlocks, ACTION_APPROVE, ACTION_DECLINE } from './slack-blocks.js';

describe('approvalBlocks', () => {
  it('renders an actions block with approve and decline buttons carrying the thread ts', () => {
    const blocks = approvalBlocks('*Fix login*', 't123');
    const actions = blocks.find((b) => b.type === 'actions');
    assert.ok(actions, 'has an actions block');

    const ids = actions.elements.map((e) => e.action_id);
    assert.deepEqual(ids, [ACTION_APPROVE, ACTION_DECLINE]);
    assert.ok(actions.elements.every((e) => e.value === 't123'), 'every button carries the thread ts');
  });

  it('includes the draft summary as a section', () => {
    const blocks = approvalBlocks('*Fix login*\n*Priority*: High', 't1');
    const section = blocks.find((b) => b.type === 'section');
    assert.match(section.text.text, /Fix login/);
  });
});

describe('resolvedBlocks', () => {
  it('replaces actions with a read-only context footer (no buttons)', () => {
    const blocks = resolvedBlocks('*Fix login*', ':white_check_mark: Created ENG-1');
    assert.ok(!blocks.some((b) => b.type === 'actions'), 'no actions block remains');
    const ctx = blocks.find((b) => b.type === 'context');
    assert.match(ctx.elements[0].text, /ENG-1/);
  });
});
