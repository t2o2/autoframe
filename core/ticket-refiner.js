/**
 * ticket-refiner.js — conversational ticket refinement state machine.
 *
 * Drives a multi-turn Claude conversation per Slack thread until a draft is
 * ready, then hands off to the adapter which presents Approve / Cancel BUTTONS
 * (Block Kit) — the user never types "yes". Approval/decline arrive as explicit
 * actions (approve/decline), not parsed free text.
 *
 * Conversation lifecycle per thread:
 *   refining → (Claude emits draft) → awaiting_approval
 *     → approve() → creating → done
 *     → decline() → cancelled
 *     → user types a change → refining (revise the draft)
 */

const SYSTEM_PROMPT = `You are a Linear ticket-writing assistant embedded in Slack.
Your goal: help the user craft a clear, actionable ticket through a brief focused conversation.

Rules:
- Ask ONE question at a time — short and direct.
- You need: the problem/goal, acceptance criteria, and optionally priority and size.
- Usually 2–4 exchanges is enough; don't over-question if the message is already detailed.
- Keep your replies under 120 words.

When you have enough information, output ONLY the following JSON block and nothing else
(the app renders it as an approval card with Approve/Cancel buttons — do NOT ask the
user to reply "yes", and do NOT add any prose around the JSON):
\`\`\`json
{"action":"create_ticket","title":"...","description":"...","priority":3}
\`\`\`
- title: concise, actionable, <80 chars
- description: 2–4 sentence problem statement, then a blank line, then "Acceptance criteria:" and bullet lines
- priority values: 1=Urgent 2=High 3=Medium 4=Low

If the user asks to revise after seeing the draft, incorporate the change and output a fresh JSON block.
If the user says "cancel" or "stop", reply: "Got it, cancelled." and output nothing else.`;

const PRIORITY_MAP = { Urgent: 1, High: 2, Medium: 3, Low: 4 };
const PRIORITY_LABEL = { 1: 'Urgent', 2: 'High', 3: 'Medium', 4: 'Low' };

/** Render a draft as the markdown shown on the Slack approval card. */
export function renderDraftSummary(draft) {
  const label = PRIORITY_LABEL[draft.priority] ?? 'Medium';
  return `*${draft.title}*\n*Priority*: ${label}\n\n${draft.description}`;
}

export class TicketRefiner {
  constructor(claudeChat) {
    this.claude = claudeChat;
    /** @type {Map<string, {messages: object[], status: string, draft?: object}>} */
    this.conversations = new Map();
  }

  /** Returns the live conversation for a thread, or undefined if not started. */
  get(threadTs) {
    return this.conversations.get(threadTs);
  }

  /**
   * Process a user message in a thread. Starts the conversation if new.
   *
   * @returns {Promise<
   *   | { type: 'reply'; text: string }
   *   | { type: 'draft'; draft: object }
   *   | { type: 'cancelled' }
   *   | null
   * >}
   */
  async processMessage(threadTs, userText) {
    let conv = this.conversations.get(threadTs);
    if (!conv) {
      conv = { messages: [], status: 'refining' };
      this.conversations.set(threadTs, conv);
    }
    // Once we're acting on the draft (creating) or finished, ignore further text.
    if (conv.status === 'creating' || conv.status === 'done' || conv.status === 'cancelled') {
      return null;
    }

    // A typed message after a draft is a revision request — drop back to refining.
    if (conv.status === 'awaiting_approval') {
      conv.status = 'refining';
      conv.draft = undefined;
    }

    conv.messages.push({ role: 'user', content: userText });

    const reply = await this.claude.chat(conv.messages, SYSTEM_PROMPT);
    conv.messages.push({ role: 'assistant', content: reply });

    // Cancellation signalled by Claude in text.
    if (/got it.*cancel/i.test(reply)) {
      conv.status = 'cancelled';
      return { type: 'cancelled' };
    }

    // Draft ready — present buttons, do NOT auto-create.
    const match = reply.match(/```json\s*([\s\S]+?)\s*```/);
    if (match) {
      try {
        const parsed = JSON.parse(match[1]);
        if (parsed.action === 'create_ticket') {
          if (typeof parsed.priority === 'string') {
            parsed.priority = PRIORITY_MAP[parsed.priority] ?? 3;
          }
          conv.status = 'awaiting_approval';
          conv.draft = parsed;
          return { type: 'draft', draft: parsed };
        }
      } catch {
        // fall through — treat as plain reply
      }
    }

    return { type: 'reply', text: reply };
  }

  /**
   * Approve the draft awaiting approval (Approve button). Returns the draft to
   * create, or null if there is nothing to approve (e.g. a double click).
   */
  approve(threadTs) {
    const conv = this.conversations.get(threadTs);
    if (!conv || conv.status !== 'awaiting_approval' || !conv.draft) return null;
    conv.status = 'creating';
    return conv.draft;
  }

  /** Decline the draft (Cancel button). Returns true if a conversation was cancelled. */
  decline(threadTs) {
    const conv = this.conversations.get(threadTs);
    if (!conv || conv.status === 'done' || conv.status === 'cancelled') return false;
    conv.status = 'cancelled';
    return true;
  }

  markDone(threadTs) {
    const conv = this.conversations.get(threadTs);
    if (conv) conv.status = 'done';
  }
}
