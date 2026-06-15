/**
 * scheduler.js — tick-driven state machine that reconciles + dispatches tickets.
 *
 * The claim store is the single source of truth for in-flight work. A claim is
 * held only while a stage is actively processing a ticket; it is released the
 * moment the agent finishes, so the same ticket can be processed again later
 * (the claim only prevents concurrent pickup, not re-processing).
 *
 * tick() steps:
 *  1. For each stage, list running claims; revert any with no recent heartbeat.
 *     Staleness is measured from the last heartbeat written by the agent's onEvent
 *     stream, falling back to startedAt when no heartbeat has been sent yet —
 *     baseline = max(startedAt, lastHeartbeat). A claim is stale when that
 *     baseline is older than stale_threshold_s. An agent writing stdout keeps
 *     resetting its clock (heartbeat fires at most once per HEARTBEAT_INTERVAL_MS
 *     to avoid Redis churn); a silent/dead agent's heartbeat goes stale and the
 *     revert fires before the Redis TTL would expire. Heartbeats also refresh the
 *     claim TTL, so a live agent running past the original TTL never loses its
 *     claim to expiry → the dispatch pass never re-acquires it (no double-exec).
 *     Stale claims from ANY container are reverted — a dead container can't revert
 *     its own, so a live one does it, releasing with the holder's owner. The revert
 *     is never silent: a best-effort explanatory comment is posted to the ticket
 *     (via tracker.comment, when available) so a timed-out/crashed agent's revert
 *     carries a reason instead of leaving the human to guess. A comment failure
 *     never blocks the revert.
 *  2. For each enabled stage, fetchCandidates and sortTickets.
 *  3. For each sorted candidate: skip if already claimed; acquire claim and fire
 *     agent.run() asynchronously (fire-and-forget with error handling).
 *  4. Respect the per-container concurrency cap from config.dispatch.concurrency:
 *     the count only includes claims held by THIS container's owner, so each
 *     container dispatches up to `concurrency` agents independently.
 */

import { sortTickets } from './dispatch.js';

const SECONDS_TO_MS = 1000;
const HEARTBEAT_INTERVAL_MS = 30 * SECONDS_TO_MS;

/**
 * @typedef {Object} SchedulerDeps
 * @property {import('./ports.js').TrackerPort}  tracker
 * @property {import('./ports.js').AgentPort}    agent
 * @property {import('./ports.js').ClaimPort}    claims
 * @property {import('./ports.js').ClockPort}    clock
 * @property {import('./ports.js').StageConfig[]} stages
 * @property {{ dispatch: { concurrency: number } }} config
 * @property {string} [owner]   container identity; claims acquired here are tagged
 *                              with it and the concurrency cap counts only these
 */

/**
 * Create a scheduler instance.
 *
 * @param {SchedulerDeps} deps
 * @returns {{ tick(): Promise<void> }}
 */
export function createScheduler({ tracker, agent, claims, clock, stages, config, owner = 'engine' }) {
  const concurrency = config.dispatch.concurrency;

  /**
   * Count tickets THIS container is running across all stages, derived from live
   * claims filtered by owner — the concurrency cap is per-container, so another
   * container's in-flight work does not consume this container's slots. Computed
   * once per tick after the stale-revert pass; the dispatch loop then tracks
   * newly-acquired claims with a local counter instead of re-scanning Redis for
   * every candidate.
   *
   * @returns {Promise<number>}
   */
  async function _runningCount() {
    let count = 0;
    for (const stage of stages) {
      const running = await claims.listRunning(stage.name);
      count += running.filter((r) => r.owner === owner).length;
    }
    return count;
  }

  return {
    async tick() {
      const now = clock.now();

      for (const stage of stages) {
        const running = await claims.listRunning(stage.name);
        const thresholdMs = stage.stale_threshold_s * SECONDS_TO_MS;

        for (const record of running) {
          // Staleness is driven by the agent's heartbeat — each onEvent write
          // updates lastHeartbeat in the claim and refreshes the Redis TTL.
          // A claim younger than the threshold can never be stale (heartbeat can
          // only push the baseline newer, never older), so skip early.
          if (now - record.startedAt <= thresholdMs) continue;

          // Past the claim age: use the most recent heartbeat as the baseline.
          // Falls back to startedAt when no heartbeat has been sent yet (e.g. the
          // agent was dispatched but hasn't produced any stdout — silent-dead
          // agents revert at startedAt + threshold via this path).
          const baselineMs = Math.max(record.startedAt, record.lastHeartbeat ?? 0);
          const ageMs = now - baselineMs;
          if (ageMs > thresholdMs) {
            try {
              await tracker.revertTicket(record.ticketId, stage.revert);
              // Release with the holder's own owner: deletes iff still owned by
              // the (possibly dead, possibly remote) container we observed, so a
              // freshly re-acquired claim is not clobbered.
              await claims.release(record.ticketId, record.owner, stage.name);
              // Explain the revert so it is never silent. A stale agent may have
              // crashed/timed out before it could report, leaving the ticket in
              // `revert` with no context for the human. Best-effort: a comment
              // failure (or a tracker without `comment`) must never block the
              // revert itself.
              try {
                const minutes = Math.max(1, Math.round(stage.stale_threshold_s / 60));
                await tracker.comment?.(
                  record.ticketId,
                  `⏱\uFE0F The **${stage.stage_verb ?? stage.name}** stage stopped responding — no heartbeat for over ${minutes} min (container \`${record.owner}\` likely crashed or timed out). Automatically reverted to **${stage.revert}**. No work was lost; re-trigger the stage or handle it manually, and check the engine logs for \`${record.owner}\`.`,
                );
              } catch (commentErr) {
                console.error(
                  `[scheduler] Reverted stale ticket ${record.ticketId} but failed to post explanation: ${commentErr.message}`,
                );
              }
            } catch (err) {
              console.error(
                `[scheduler] Failed to revert stale ticket ${record.ticketId}: ${err.message}`,
              );
            }
          }
        }
      }

      let runningCount = await _runningCount();

      for (const stage of stages) {
        if (runningCount >= concurrency) break;

        let candidates;
        try {
          candidates = await tracker.fetchCandidates(stage);
        } catch (err) {
          console.error(`[scheduler] fetchCandidates failed for stage ${stage.name}: ${err.message}`);
          continue;
        }

        const sorted = sortTickets(candidates);

        for (const ticket of sorted) {
          if (runningCount >= concurrency) break;

          if (await claims.isOwned(ticket.id, stage.name)) continue;

          const acquired = await claims.acquire(ticket.id, owner, stage.name, stage.stale_threshold_s);
          if (!acquired) continue;
          runningCount++;

          const command = `${stage.command} ${ticket.id}`;
          const attemptNumber = 1;

          let lastHeartbeatAt = 0;
          agent
            .run({
              command,
              cwd: '/workspace/worktrees',
              attempt: attemptNumber,
              onEvent: () => {
                const t = clock.now();
                if (t - lastHeartbeatAt >= HEARTBEAT_INTERVAL_MS) {
                  lastHeartbeatAt = t;
                  claims.heartbeat(ticket.id, owner, stage.name, t, stage.stale_threshold_s).catch(() => {});
                }
              },
            })
            .then(async () => {
              // Releasing the claim frees the ticket for re-processing; the claim
              // was the only thing preventing another worker from picking it up.
              await claims.release(ticket.id, owner, stage.name);
            })
            .catch(async (err) => {
              console.error(`[scheduler] agent.run failed for ${ticket.id}: ${err.message}`);
              await claims.release(ticket.id, owner, stage.name);
            });
        }
      }
    },
  };
}
