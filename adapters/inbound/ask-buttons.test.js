import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  encodeAskValue, decodeAskValue, resolveLabel, askBlocks, isAskAction,
  optsKey, ansKey, ACTION_ASK,
} from './ask-buttons.js';

describe('encode/decodeAskValue', () => {
  it('round-trips a numeric option index', () => {
    assert.deepEqual(decodeAskValue(encodeAskValue('abc123', 2)), { key: 'abc123', idx: 2 });
  });

  it('round-trips skip', () => {
    assert.deepEqual(decodeAskValue(encodeAskValue('abc123', 'skip')), { key: 'abc123', idx: 'skip' });
  });

  it('keeps keys containing colons and dashes intact (splits on the last pipe)', () => {
    assert.deepEqual(decodeAskValue('ENG-12:deadbeef|3'), { key: 'ENG-12:deadbeef', idx: 3 });
  });

  it('returns null idx for malformed values', () => {
    assert.deepEqual(decodeAskValue('no-pipe'), { key: '', idx: null });
  });
});

describe('resolveLabel', () => {
  const opts = JSON.stringify(['Use Postgres', 'Use Redis', 'Use SQLite']);

  it('maps an index to its option text', () => {
    assert.equal(resolveLabel(opts, 1), 'Use Redis');
  });

  it('returns empty string for skip', () => {
    assert.equal(resolveLabel(opts, 'skip'), '');
  });

  it('returns empty string for an out-of-range index', () => {
    assert.equal(resolveLabel(opts, 9), '');
  });

  it('returns empty string when options are missing/corrupt', () => {
    assert.equal(resolveLabel(undefined, 0), '');
    assert.equal(resolveLabel('{bad json', 0), '');
  });
});

describe('askBlocks', () => {
  it('renders a button per option plus a skip button, each carrying the key', () => {
    const blocks = askBlocks('*ENG-1* — pick one', ['A', 'B', 'C'], 'k1');
    const buttons = blocks.filter((b) => b.type === 'actions').flatMap((b) => b.elements);
    assert.equal(buttons.length, 4); // 3 options + skip
    assert.ok(buttons.every((btn) => btn.value.startsWith('k1|')));
    assert.equal(buttons.at(-1).value, 'k1|skip');
  });

  it('chunks more than 5 options into multiple actions rows (Slack limit)', () => {
    const opts = Array.from({ length: 7 }, (_, i) => `opt${i}`);
    const blocks = askBlocks('*q*', opts, 'k');
    const actionRows = blocks.filter((b) => b.type === 'actions');
    // 7 options → rows of 5 + 2 = 2 option rows, plus the skip row = 3
    assert.equal(actionRows.length, 3);
    assert.ok(actionRows.every((r) => r.elements.length <= 5));
  });

  it('truncates button labels to Slack’s 75-char limit', () => {
    const long = 'x'.repeat(200);
    const blocks = askBlocks('*q*', [long], 'k');
    const btn = blocks.find((b) => b.type === 'actions').elements[0];
    assert.ok(btn.text.text.length <= 75);
  });
});

describe('isAskAction', () => {
  it('recognizes ask-human action ids', () => {
    assert.equal(isAskAction(`${ACTION_ASK}_2`), true);
    assert.equal(isAskAction(`${ACTION_ASK}_skip`), true);
  });

  it('rejects ticket-approval and unknown action ids', () => {
    assert.equal(isAskAction('ticket_approve'), false);
    assert.equal(isAskAction(undefined), false);
  });
});

describe('redis key helpers', () => {
  it('namespace opts and answers by key', () => {
    assert.equal(optsKey('k1'), 'askhuman:opts:k1');
    assert.equal(ansKey('k1'), 'askhuman:ans:k1');
  });
});
