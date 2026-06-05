/**
 * poll-driver.js — drives scheduler.tick() on a configurable interval.
 *
 * The driver calls tick() immediately on start, then repeats every pollIntervalMs.
 * Errors in tick() are caught and logged; the loop continues.
 */

/**
 * @typedef {Object} PollDriverOpts
 * @property {{ tick(): Promise<void> }} scheduler
 * @property {number} pollIntervalMs
 * @property {() => boolean} [shouldStop]   optional stop predicate
 */

/**
 * Create and start a poll driver.
 *
 * @param {PollDriverOpts} opts
 * @returns {{ stop(): void }}
 */
export function createPollDriver({ scheduler, pollIntervalMs, shouldStop }) {
  let stopped = false;
  let timeoutHandle;

  async function runTick() {
    if (stopped || shouldStop?.()) {
      stopped = true;
      return;
    }

    try {
      await scheduler.tick();
    } catch (err) {
      console.error(`[poll-driver] tick() error: ${err.message}`);
    }

    if (!stopped && !shouldStop?.()) {
      timeoutHandle = setTimeout(runTick, pollIntervalMs);
    }
  }

  runTick();

  return {
    stop() {
      stopped = true;
      if (timeoutHandle) clearTimeout(timeoutHandle);
    },
  };
}
