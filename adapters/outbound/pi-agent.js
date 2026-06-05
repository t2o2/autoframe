/**
 * pi-agent.js — AgentPort scaffold for the `pi` binary.
 *
 * The pi binary's stream format is not yet documented.
 * This is a scaffold only — no stream format implemented.
 *
 * UNVERIFIED: needs live run with `pi` binary and documented stream format.
 */

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

/**
 * Create a Pi agent adapter.
 *
 * @returns {import('../../core/ports.js').AgentPort}
 */
export function createPiAgent() {
  return {
    // UNVERIFIED: needs live run with `pi` binary
    async run({ command, cwd, attempt, onEvent }) {
      const args = [
        '--dangerously-skip-permissions',
        '--no-session-persistence',
        '-p', command,
        '--output-format', 'stream-json',
        '--include-partial-messages',
      ];

      const child = spawn('pi', args, {
        cwd,
        env: { ...process.env },
        stdio: ['ignore', 'pipe', 'pipe'],
      });

      const rl = createInterface({ input: child.stdout });

      rl.on('line', (line) => {
        const trimmed = line.trim();
        if (!trimmed) return;
        onEvent({ kind: 'text', text: trimmed });
      });

      const exitCode = await new Promise((resolve, reject) => {
        child.on('error', reject);
        child.on('close', resolve);
      });

      return { exitCode, verdict: undefined };
    },
  };
}
