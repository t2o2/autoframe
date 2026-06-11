/**
 * ticket-refiner.js — conversational ticket refinement state machine.
 *
 * Drives a multi-turn Claude conversation per Slack thread until the user
 * approves a ticket draft, then signals creation.
 *
 * Conversation lifecycle per thread:
 *   refining → (user approves draft) → create_ticket signal → done
 */

const SYSTEM_PROMPT = `You are a Linear ticket-writing assistant embedded in Slack.
Your goal: help the user craft a clear, actionable ticket through a brief focused conversation.

Rules:
- Ask ONE question at a time — short and direct.
- You need: the problem/goal, acceptance criteria, and optionally priority and size.
- Usually 2–4 exchanges is enough; don't over-question if the message is already detailed.
- Keep your replies under 120 words.

When you have enough information, present a draft in this exact format:
---
*Title*: <concise, actionable, <80 chars>
*Priority*: Urgent | High | Medium | Low
*Description*:
<2–4 sentence problem statement>

*Acceptance criteria*:
- <criterion>
- <criterion>
---
Then ask: "Does this look right? Reply *yes* to create the ticket, or tell me what to change."

When the user approves (yes / looks good / create it / ship it / perfect / lgtm / 👍):
Output ONLY the following JSON block and nothing else:
\`\`\`json
{"action":"create_ticket","title":"...","description":"...","priority":3}
\`\`\`
priority values: 1=Urgent 2=High 3=Medium 4=Low

Never create the ticket without explicit approval.
If the user says "cancel" or "stop", reply: "Got it, cancelled." and output nothing else.`;

const PRIORITY_MAP = { Urgent: 1, High: 2, Medium: 3, Low: 4 };

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
   *   | { type: 'create_ticket'; draft: object }
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
    if (conv.status === 'done' || conv.status === 'cancelled') return null;

    conv.messages.push({ role: 'user', content: userText });

    const reply = await this.claude.chat(conv.messages, SYSTEM_PROMPT);
    conv.messages.push({ role: 'assistant', content: reply });

    // Check for cancellation signal from Claude
    if (/got it.*cancel/i.test(reply)) {
      conv.status = 'cancelled';
      return { type: 'cancelled' };
    }

    // Check for ticket JSON output
    const match = reply.match(/```json\s*([\s\S]+?)\s*```/);
    if (match) {
      try {
        const parsed = JSON.parse(match[1]);
        if (parsed.action === 'create_ticket') {
          // Normalize priority from string if present
          if (typeof parsed.priority === 'string') {
            parsed.priority = PRIORITY_MAP[parsed.priority] ?? 3;
          }
          conv.status = 'creating';
          conv.draft = parsed;
          return { type: 'create_ticket', draft: parsed };
        }
      } catch {
        // fall through — treat as plain reply
      }
    }

    return { type: 'reply', text: reply };
  }

  markDone(threadTs) {
    const conv = this.conversations.get(threadTs);
    if (conv) conv.status = 'done';
  }
}
