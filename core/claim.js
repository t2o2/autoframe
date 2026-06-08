/**
 * claim.js — in-memory claim state machine.
 *
 * The claim store IS the source of truth for "who is working on what right now".
 * A claim exists only while a stage is actively processing a ticket; release()
 * deletes it so the ticket becomes claimable (and therefore re-processable) again.
 *
 * Claims are namespaced by stage — ENG-42 in "process" and "review" are independent,
 * matching the Redis-backed store (autoframe:claim:{stage}:{ticketId}).
 *
 * State transitions (per stage):
 *   Unclaimed   --acquire()-->    Running
 *   Running     --release()-->    Unclaimed   (success or failure — caller decides linear revert)
 *   Running     --queueRetry()--> RetryQueued (Phase 3: backoff not yet implemented)
 *   RetryQueued --acquire()-->    Running     (when next_at passes — Phase 3 timer)
 *
 * ClaimPort interface:
 *   acquire(ticketId, owner, stage)   → boolean (false if already owned)
 *   release(ticketId, owner, stage)   → void    (no-op if not owned by this owner)
 *   queueRetry(ticketId, retryAt, stage) → void
 *   isOwned(ticketId, stage)          → boolean
 *   listRunning(stage)                → [{ ticketId, startedAt }]  (Running only)
 *   getState(ticketId, stage)         → 'Unclaimed'|'Running'|'RetryQueued'
 */

const STATE_UNCLAIMED = 'Unclaimed';
const STATE_RUNNING = 'Running';
const STATE_RETRY_QUEUED = 'RetryQueued';

/**
 * @typedef {{ state: 'Unclaimed' }} UnclaimedEntry
 * @typedef {{ state: 'Running', owner: string, startedAt: number, ticketId: string, stage: string, lastHeartbeat?: number }} RunningEntry
 * @typedef {{ state: 'RetryQueued', retryAt: number }} RetryQueuedEntry
 * @typedef {UnclaimedEntry | RunningEntry | RetryQueuedEntry} ClaimEntry
 */

/**
 * Create an in-memory claim store.
 * Safe for single-process use (--stage all or single-container deployment).
 *
 * @param {{ clock?: { now(): number } }} [opts]
 * @returns {import('./ports.js').ClaimPort & {
 *   queueRetry(ticketId: string, retryAt: number, stage?: string): Promise<void>,
 *   getState(ticketId: string, stage?: string): Promise<string>
 * }}
 */
export function createClaimStore({ clock = { now: () => Date.now() } } = {}) {
  /** @type {Map<string, ClaimEntry>} */
  const claims = new Map();

  function _key(ticketId, stage) {
    return `${stage}:${ticketId}`;
  }

  function _getEntry(ticketId, stage) {
    return claims.get(_key(ticketId, stage)) ?? { state: STATE_UNCLAIMED };
  }

  return {
    /**
     * Attempt to acquire a claim on ticketId for owner in stage.
     * Returns false if already Running or RetryQueued.
     *
     * @param {string} ticketId
     * @param {string} owner
     * @param {string} [stage]
     * @returns {Promise<boolean>}
     */
    async acquire(ticketId, owner, stage, _ttl) {
      const entry = _getEntry(ticketId, stage);

      if (entry.state === STATE_RUNNING) {
        return false;
      }

      if (entry.state === STATE_RETRY_QUEUED) {
        return false;
      }

      claims.set(_key(ticketId, stage), {
        state: STATE_RUNNING,
        owner,
        startedAt: clock.now(),
        ticketId,
        stage,
      });
      return true;
    },

    /**
     * Release a claim. No-op if the ticket is not currently Running under this owner.
     *
     * @param {string} ticketId
     * @param {string} owner
     * @param {string} [stage]
     */
    async release(ticketId, owner, stage) {
      const entry = _getEntry(ticketId, stage);
      if (entry.state !== STATE_RUNNING) return;
      if (entry.owner !== owner) return;
      claims.delete(_key(ticketId, stage));
    },

    /**
     * Transition a Running claim to RetryQueued with a scheduled retry time.
     * No-op if not currently Running.
     *
     * @param {string} ticketId
     * @param {number} retryAt   ms timestamp (Date.now()-compatible)
     * @param {string} [stage]
     */
    async queueRetry(ticketId, retryAt, stage) {
      const entry = _getEntry(ticketId, stage);
      if (entry.state !== STATE_RUNNING) return;
      claims.set(_key(ticketId, stage), { state: STATE_RETRY_QUEUED, retryAt });
    },

    /**
     * Check whether a ticket is currently claimed (Running or RetryQueued) in stage.
     *
     * @param {string} ticketId
     * @param {string} [stage]
     * @returns {Promise<boolean>}
     */
    async isOwned(ticketId, stage) {
      const entry = _getEntry(ticketId, stage);
      return entry.state !== STATE_UNCLAIMED;
    },

    /**
     * List tickets currently Running in stage. RetryQueued claims are excluded —
     * they are not occupying a concurrency slot.
     *
     * @param {string} stage
     * @returns {Promise<{ ticketId: string, startedAt: number, owner: string }[]>}
     */
    async listRunning(stage) {
      const results = [];
      for (const entry of claims.values()) {
        if (entry.state === STATE_RUNNING && entry.stage === stage) {
          results.push({
            ticketId: entry.ticketId,
            startedAt: entry.startedAt,
            owner: entry.owner,
            lastHeartbeat: entry.lastHeartbeat,
          });
        }
      }
      return results;
    },

    /**
     * Update the lastHeartbeat timestamp for a running claim. No-op if the
     * ticket is not Running under this owner (safe to call unconditionally).
     * Called by the agent dispatcher to keep the claim alive; the stale pass
     * reads lastHeartbeat so an actively-running agent is never reverted.
     *
     * @param {string} ticketId
     * @param {string} owner
     * @param {string} stage
     * @param {number} ts   ms epoch
     */
    async heartbeat(ticketId, owner, stage, ts) {
      const entry = _getEntry(ticketId, stage);
      if (entry.state !== STATE_RUNNING) return;
      if (entry.owner !== owner) return;
      entry.lastHeartbeat = ts;
    },

    /**
     * Get the current state name for a ticket in stage.
     *
     * @param {string} ticketId
     * @param {string} [stage]
     * @returns {Promise<'Unclaimed'|'Running'|'RetryQueued'>}
     */
    async getState(ticketId, stage) {
      return _getEntry(ticketId, stage).state;
    },
  };
}
