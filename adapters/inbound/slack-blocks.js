/**
 * slack-blocks.js — pure Block Kit builders for the ticket intake bot.
 *
 * Kept dependency-free and side-effect-free so the button layout is unit
 * testable without touching Slack.
 */

export const ACTION_APPROVE = 'ticket_approve';
export const ACTION_DECLINE = 'ticket_decline';

/**
 * Build the approval card blocks for a ready draft. The draft summary renders
 * as a section; Approve / Cancel are the only ways the user responds (no typing
 * "yes"). `value` carries the thread ts so the action handler can route back.
 *
 * @param {string} summaryMarkdown  output of renderDraftSummary()
 * @param {string} threadTs         the conversation thread, echoed in button value
 */
export function approvalBlocks(summaryMarkdown, threadTs) {
  return [
    { type: 'section', text: { type: 'mrkdwn', text: summaryMarkdown } },
    {
      type: 'actions',
      block_id: 'ticket_approval',
      elements: [
        {
          type: 'button',
          style: 'primary',
          text: { type: 'plain_text', text: 'Create ticket', emoji: true },
          action_id: ACTION_APPROVE,
          value: threadTs,
        },
        {
          type: 'button',
          style: 'danger',
          text: { type: 'plain_text', text: 'Cancel', emoji: true },
          action_id: ACTION_DECLINE,
          value: threadTs,
        },
      ],
    },
  ];
}

/**
 * Build a single read-only context line — used to replace the buttons after a
 * choice is made so the card can't be clicked twice.
 */
export function resolvedBlocks(summaryMarkdown, footer) {
  return [
    { type: 'section', text: { type: 'mrkdwn', text: summaryMarkdown } },
    { type: 'context', elements: [{ type: 'mrkdwn', text: footer }] },
  ];
}
