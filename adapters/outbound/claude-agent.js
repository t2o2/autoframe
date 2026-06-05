/**
 * claude-agent.js — AgentPort implementation for the `claude` CLI.
 *
 * Split into:
 *   mapStreamLine(line) — pure mapper for a single stream-json line, fully tested
 *   createClaudeAgent()  — spawn shell, UNVERIFIED: needs live run
 *
 * Stream-json format (one JSON object per line):
 *   { type: 'assistant', message: { content: [...] } }
 *   { type: 'result', result: 'success'|'error', usage: { input_tokens, output_tokens, total_tokens } }
 *   { type: 'system', subtype: 'init' }
 *
 * AgentEvent kinds produced:
 *   'phase'   — text starting with === or **Phase
 *   'tool'    — tool_use content blocks
 *   'text'    — text content blocks (non-phase lines)
 *   'error'   — result with is_error:true or type=='error'
 *   'tokens'  — result.usage; also scans last text lines for DONE/PASS/FAIL verdict
 */

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const PHASE_BANNER_RE = /^(===|##\s*Phase\s|\*\*Phase\s)/i;
const VERDICT_RE = /\b(DONE|PASS|FAIL)\b/;

/**
 * Map a single raw stream-json line to zero or more AgentEvents.
 * Returns an array (most lines produce one event; tokens can produce two if verdict found).
 *
 * @param {string} line              raw JSON line
 * @param {{ lastText: string }}  ctx  mutable context carrying the last text seen
 * @returns {import('../../core/ports.js').AgentEvent[]}
 */
export function mapStreamLine(line, ctx = { lastText: '' }) {
  const trimmed = line.trim();
  if (!trimmed) return [];

  let event;
  try {
    event = JSON.parse(trimmed);
  } catch {
    return [];
  }

  const etype = event.type;
  const events = [];

  if (etype === 'assistant') {
    const content = event.message?.content ?? [];
    for (const block of content) {
      if (block.type === 'text') {
        const text = block.text ?? '';
        ctx.lastText = text;
        for (const textLine of text.split('\n')) {
          if (PHASE_BANNER_RE.test(textLine.trim())) {
            events.push({ kind: 'phase', title: textLine.trim() });
          } else if (textLine.trim()) {
            events.push({ kind: 'text', text: textLine });
          }
        }
      } else if (block.type === 'tool_use') {
        const name = block.name ?? '';
        const hint = _buildToolHint(name, block.input ?? {});
        events.push({ kind: 'tool', name, ...(hint ? { hint } : {}) });
      }
    }
  } else if (etype === 'tool_use') {
    const name = event.name ?? '';
    events.push({ kind: 'tool', name });
  } else if (etype === 'result') {
    if (event.is_error) {
      const message = String(event.result ?? 'unknown error').slice(0, 300);
      events.push({ kind: 'error', message });
    }

    const usage = event.usage;
    if (usage) {
      const input = usage.input_tokens ?? 0;
      const output = usage.output_tokens ?? 0;
      const total = usage.total_tokens ?? input + output;

      const verdict = _extractVerdict(ctx.lastText);
      events.push({ kind: 'tokens', input, output, total, ...(verdict ? { verdict } : {}) });
    }
  }

  return events;
}

/**
 * Build a short hint string for a tool_use block (mirrors bash stream processor logic).
 *
 * @param {string} name
 * @param {object} input
 * @returns {string}
 */
function _buildToolHint(name, input) {
  if (name === 'Bash' || name === 'bash') {
    return ((input.command ?? '').slice(0, 80));
  }
  if (['Read', 'Edit', 'Write', 'Glob', 'Grep'].includes(name)) {
    return (input.file_path ?? input.path ?? input.pattern ?? '');
  }
  return '';
}

/**
 * Scan text for a DONE/PASS/FAIL verdict marker.
 *
 * @param {string} text
 * @returns {'DONE'|'PASS'|'FAIL'|undefined}
 */
function _extractVerdict(text) {
  const m = VERDICT_RE.exec(text ?? '');
  if (!m) return undefined;
  return /** @type {'DONE'|'PASS'|'FAIL'} */ (m[1]);
}

/**
 * Create a ClaudeAgent that spawns the `claude` CLI.
 *
 * UNVERIFIED: needs live run with a working `claude` binary in PATH.
 *
 * @returns {import('../../core/ports.js').AgentPort}
 */
export function createClaudeAgent() {
  return {
    // UNVERIFIED: needs live run with `claude` binary
    async run({ command, cwd, attempt, onEvent }) {
      const args = [
        '--dangerously-skip-permissions',
        '--no-session-persistence',
        '-p', command,
        '--output-format', 'stream-json',
        '--include-partial-messages',
      ];

      const child = spawn('claude', args, {
        cwd,
        env: { ...process.env },
        stdio: ['ignore', 'pipe', 'pipe'],
      });

      const rl = createInterface({ input: child.stdout });
      const ctx = { lastText: '' };
      let verdict;

      rl.on('line', (line) => {
        const events = mapStreamLine(line, ctx);
        for (const ev of events) {
          if (ev.kind === 'tokens' && ev.verdict) {
            verdict = ev.verdict;
          }
          onEvent(ev);
        }
      });

      const exitCode = await new Promise((resolve, reject) => {
        child.on('error', reject);
        child.on('close', resolve);
      });

      return { exitCode, verdict };
    },
  };
}
