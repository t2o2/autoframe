/**
 * claude-chat.js — Claude multi-turn chat wrapper.
 *
 * Two paths:
 *   • ANTHROPIC_API_KEY present → direct Messages API (low-latency)
 *   • OAuth only (CLAUDE_CODE_OAUTH_TOKEN) → claude -p CLI subprocess
 *     The CLI handles all auth modes so no key plumbing is needed.
 */

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const ANTHROPIC_API = 'https://api.anthropic.com/v1/messages';

export class ClaudeChat {
  constructor(apiKey, model = 'claude-sonnet-4-6') {
    this.apiKey = apiKey || null;
    this.model = model;
  }

  /**
   * Send the full conversation history and get the next assistant turn.
   *
   * @param {{ role: 'user'|'assistant', content: string }[]} messages
   * @param {string} systemPrompt
   * @returns {Promise<string>}
   */
  async chat(messages, systemPrompt) {
    if (this.apiKey) {
      return this._chatViaApi(messages, systemPrompt);
    }
    return this._chatViaCli(messages, systemPrompt);
  }

  async _chatViaApi(messages, systemPrompt) {
    const res = await fetch(ANTHROPIC_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': this.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: this.model,
        max_tokens: 1024,
        system: systemPrompt,
        messages,
      }),
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(`Claude API ${res.status}: ${body}`);
    }

    const data = await res.json();
    return data.content?.[0]?.text ?? '';
  }

  // Build a single text prompt with system context + full history and pass it
  // to `claude -p <prompt>` — same flags pattern as createClaudeAgent so the
  // OAuth token (CLAUDE_CODE_OAUTH_TOKEN) flows through env automatically.
  async _chatViaCli(messages, systemPrompt) {
    let prompt = `${systemPrompt}\n\n`;
    for (const msg of messages) {
      prompt += msg.role === 'user'
        ? `Human: ${msg.content}\n\n`
        : `Assistant: ${msg.content}\n\n`;
    }
    prompt += 'Assistant:';

    const { stdout } = await execFileAsync(
      'claude',
      [
        '--dangerously-skip-permissions',
        '--no-session-persistence',
        '-p', prompt,
        '--output-format', 'text',
      ],
      { env: { ...process.env }, timeout: 60_000 },
    );
    return stdout.trim();
  }
}
