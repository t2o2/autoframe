/**
 * ask-buttons.js — shared contract between ask-human.sh's Slack helper (which
 * POSTS the option buttons) and the slack-listen bot (the SOLE Socket Mode
 * consumer, which RECEIVES the click and relays the answer through Redis).
 *
 * Both sides import this so the action_id, button value encoding, and Redis key
 * names never drift apart.
 */

import { resolvedBlocks } from './slack-blocks.js';

export const ACTION_ASK = 'ask_human';

const SLACK_BUTTON_TEXT_MAX = 75; // Slack hard limit on button label length

/** Redis key holding the JSON options array for an ask (written by the asker). */
export const optsKey = (key) => `askhuman:opts:${key}`;
/** Redis key the answer is written to (by slack-listen) and polled (by the asker). */
export const ansKey = (key) => `askhuman:ans:${key}`;

/**
 * Encode a button value as `<key>|<idx>`. `idx` is a 0-based option index or
 * the literal 'skip'. `key` is asker-generated and never contains '|'.
 */
export function encodeAskValue(key, idx) {
  return `${key}|${idx}`;
}

/** Decode `<key>|<idx>` → { key, idx } where idx is a number or 'skip'. */
export function decodeAskValue(value) {
  const i = String(value ?? '').lastIndexOf('|');
  if (i < 0) return { key: '', idx: null };
  const key = value.slice(0, i);
  const raw = value.slice(i + 1);
  const idx = raw === 'skip' ? 'skip' : Number.parseInt(raw, 10);
  return { key, idx: Number.isNaN(idx) ? null : idx };
}

/** Resolve the chosen label from the stored options JSON. Skip / bad index → ''. */
export function resolveLabel(optsJson, idx) {
  if (idx === 'skip' || idx == null) return '';
  let opts;
  try {
    opts = JSON.parse(optsJson ?? '[]');
  } catch {
    return '';
  }
  return Array.isArray(opts) && idx >= 0 && idx < opts.length ? String(opts[idx]) : '';
}

const truncate = (s) =>
  s.length > SLACK_BUTTON_TEXT_MAX ? `${s.slice(0, SLACK_BUTTON_TEXT_MAX - 1)}…` : s;

const chunk = (arr, n) => {
  const out = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
};

/**
 * Build the ask card: a section with the question, then rows of option buttons
 * (max 5 per actions block), and a final Skip button. Every button carries the
 * asker's key so the relay can route the answer back.
 */
export function askBlocks(headerMarkdown, options, key) {
  const blocks = [{ type: 'section', text: { type: 'mrkdwn', text: headerMarkdown } }];

  chunk(options, 5).forEach((row, rowIdx) => {
    blocks.push({
      type: 'actions',
      block_id: `ask_row_${rowIdx}`,
      elements: row.map((label, i) => {
        const idx = rowIdx * 5 + i;
        return {
          type: 'button',
          text: { type: 'plain_text', text: truncate(String(label)), emoji: true },
          action_id: `${ACTION_ASK}_${idx}`,
          value: encodeAskValue(key, idx),
        };
      }),
    });
  });

  blocks.push({
    type: 'actions',
    block_id: 'ask_skip',
    elements: [
      {
        type: 'button',
        style: 'danger',
        text: { type: 'plain_text', text: 'Skip', emoji: true },
        action_id: `${ACTION_ASK}_skip`,
        value: encodeAskValue(key, 'skip'),
      },
    ],
  });

  return blocks;
}

/** Read-only card shown after a choice is made (no buttons). */
export function askResolvedBlocks(headerMarkdown, footer) {
  return resolvedBlocks(headerMarkdown, footer);
}

/** True if an action_id belongs to an ask-human button. */
export function isAskAction(actionId) {
  return typeof actionId === 'string' && actionId.startsWith(`${ACTION_ASK}_`);
}
