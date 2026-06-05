/**
 * claim.js — in-memory claim state machine.
 *
 * State transitions:
 *   Unclaimed   --acquire()-->    Running
 *   Running     --release()-->    Unclaimed   (success or failure — caller decides linear revert)
 *   Running     --queueRetry()--> RetryQueued (Phase 3: backoff not yet implemented)
 *   RetryQueued --acquire()-->    Running     (when next_at passes — Phase 3 timer)
 *
 * ClaimPort interface:
 *   acquire(ticketId, owner)      → boolean (false if already owned by another)
 *   release(ticketId, owner)      → void    (no-op if not owned by this owner)
 *   queueRetry(ticketId, retryAt) → void
 *   isOwned(ticketId)             → boolean
 *   getState(ticketId)            → 'Unclaimed'|'Running'|'RetryQueued'
 */

const STATE_UNCLAIMED = 'Unclaimed';
const STATE_RUNNING = 'Running';
const STATE_RETRY_QUEUED = 'RetryQueued';

/**
 * @typedef {{ state: 'Unclaimed' }} UnclaimedEntry
 * @typedef {{ state: 'Running', owner: string, startedAt: number }} RunningEntry
 * @typedef {{ state: 'RetryQueued', retryAt: number }} RetryQueuedEntry
 * @typedef {UnclaimedEntry | RunningEntry | RetryQueuedEntry} ClaimEntry
 */

/**
 * Create an in-memory claim store.
 * Safe for single-process use (--stage all or single-container deployment).
 *
 * @returns {import('./ports.js').ClaimPort & {
 *   queueRetry(ticketId: string, retryAt: number): void,
 *   getState(ticketId: string): string
 * }}
 */
export function createClaimStore() {
  /** @type {Map<string, ClaimEntry>} */
  const claims = new Map();

  function _getEntry(ticketId) {
    return claims.get(ticketId) ?? { state: STATE_UNCLAIMED };
  }

  return {
    /**
     * Attempt to acquire a claim on ticketId for owner.
     * Returns false if already Running under a different owner, or if RetryQueued.
     *
     * @param {string} ticketId
     * @param {string} owner
     * @returns {boolean}
     */
    async acquire(ticketId, owner, _stage, _ttl) {
      const entry = _getEntry(ticketId);

      if (entry.state === STATE_RUNNING) {
        return false;
      }

      if (entry.state === STATE_RETRY_QUEUED) {
        return false;
      }

      claims.set(ticketId, { state: STATE_RUNNING, owner, startedAt: Date.now() });
      return true;
    },

    /**
     * Release a claim. No-op if the ticket is not currently Running under this owner.
     *
     * @param {string} ticketId
     * @param {string} owner
     */
    async release(ticketId, owner, _stage) {
      const entry = _getEntry(ticketId);
      if (entry.state !== STATE_RUNNING) return;
      if (entry.owner !== owner) return;
      claims.delete(ticketId);
    },

    /**
     * Transition a Running claim to RetryQueued with a scheduled retry time.
     * No-op if not currently Running.
     *
     * @param {string} ticketId
     * @param {number} retryAt   ms timestamp (Date.now()-compatible)
     */
    async queueRetry(ticketId, retryAt, _stage) {
      const entry = _getEntry(ticketId);
      if (entry.state !== STATE_RUNNING) return;
      claims.set(ticketId, { state: STATE_RETRY_QUEUED, retryAt });
    },

    /**
     * Check whether a ticket is currently claimed (Running or RetryQueued).
     *
     * @param {string} ticketId
     * @param {string} [_stage]
     * @returns {Promise<boolean>}
     */
    async isOwned(ticketId, _stage) {
      const entry = _getEntry(ticketId);
      return entry.state !== STATE_UNCLAIMED;
    },

    /**
     * Get the current state name for a ticket.
     *
     * @param {string} ticketId
     * @param {string} [_stage]
     * @returns {Promise<'Unclaimed'|'Running'|'RetryQueued'>}
     */
    async getState(ticketId, _stage) {
      return _getEntry(ticketId).state;
    },
  };
}
