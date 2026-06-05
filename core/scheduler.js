/**
 * scheduler.js — tick-driven state machine that reconciles + dispatches tickets.
 *
 * tick() steps:
 *  1. For each stage, list running attempts from store; revert any that exceeded
 *     stale_threshold_s (in seconds → compare as ms against clock.now()).
 *  2. For each enabled stage, fetchCandidates and sortTickets.
 *  3. For each sorted candidate: skip if already claimed; acquire claim and fire
 *     agent.run() asynchronously (fire-and-forget with error handling).
 *  4. Respect the global concurrency cap from config.dispatch.concurrency.
 */

import { sortTickets } from './dispatch.js';

const SECONDS_TO_MS = 1000;

/**
 * @typedef {Object} SchedulerDeps
 * @property {import('./ports.js').TrackerPort}  tracker
 * @property {import('./ports.js').AgentPort}    agent
 * @property {import('./ports.js').ClaimPort}    claims
 * @property {import('./ports.js').StorePort}    store
 * @property {import('./ports.js').ClockPort}    clock
 * @property {import('./ports.js').StageConfig[]} stages
 * @property {{ dispatch: { concurrency: number } }} config
 */

/**
 * Create a scheduler instance.
 *
 * @param {SchedulerDeps} deps
 * @returns {{ tick(): Promise<void> }}
 */
export function createScheduler({ tracker, agent, claims, store, clock, stages, config }) {
  const concurrency = config.dispatch.concurrency;

  /**
   * Count currently running tickets across all stages.
   * Uses store records as the source — the dispatcher writes a record immediately
   * before fire-and-forget so the count is accurate within the same tick.
   *
   * @returns {number}
   */
  function _runningCount() {
    let count = 0;
    for (const stage of stages) {
      count += store.listRunning(stage.name).length;
    }
    return count;
  }

  return {
    async tick() {
      const now = clock.now();

      for (const stage of stages) {
        const running = store.listRunning(stage.name);
        const thresholdMs = stage.stale_threshold_s * SECONDS_TO_MS;

        for (const record of running) {
          const ageMs = now - record.startedAt;
          if (ageMs > thresholdMs) {
            try {
              await tracker.revertTicket(record.ticketId, stage.revert);
              await claims.release(record.ticketId, 'engine', stage.name);
            } catch (err) {
              console.error(
                `[scheduler] Failed to revert stale ticket ${record.ticketId}: ${err.message}`,
              );
            }
          }
        }
      }

      for (const stage of stages) {
        if (_runningCount() >= concurrency) break;

        let candidates;
        try {
          candidates = await tracker.fetchCandidates(stage);
        } catch (err) {
          console.error(`[scheduler] fetchCandidates failed for stage ${stage.name}: ${err.message}`);
          continue;
        }

        const sorted = sortTickets(candidates);

        for (const ticket of sorted) {
          if (_runningCount() >= concurrency) break;

          if (await claims.isOwned(ticket.id, stage.name)) continue;

          const acquired = await claims.acquire(ticket.id, 'engine', stage.name, stage.stale_threshold_s);
          if (!acquired) continue;

          const startedAt = clock.now();
          store.writeAttempt(ticket.id, stage.name, { ticketId: ticket.id, startedAt, stage: stage.name });

          const command = `${stage.command} ${ticket.id}`;
          const attemptNumber = 1;

          agent
            .run({
              command,
              cwd: '/workspace/worktrees',
              attempt: attemptNumber,
              onEvent: () => {},
            })
            .then(async () => {
              // UNVERIFIED: completion does not clear the store attempt record —
              // listRunning() grows unbounded across ticks; needs a StorePort.deleteAttempt()
              // method and a multi-tick integration test before this is production-safe.
              await claims.release(ticket.id, 'engine', stage.name);
            })
            .catch(async (err) => {
              console.error(`[scheduler] agent.run failed for ${ticket.id}: ${err.message}`);
              // UNVERIFIED: same unbounded-store issue as the success path above.
              await claims.release(ticket.id, 'engine', stage.name);
            });
        }
      }
    },
  };
}
