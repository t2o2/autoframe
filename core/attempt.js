/**
 * attempt.js — run-attempt lifecycle state machine.
 *
 * Valid state transitions:
 *   PREPARING   → LAUNCHING
 *   PREPARING   → CANCELED     (aborted before launch)
 *   LAUNCHING   → STREAMING
 *   STREAMING   → SUCCEEDED
 *   STREAMING   → FAILED
 *   STREAMING   → TIMED_OUT
 *   STREAMING   → STALLED
 *   STREAMING   → CANCELED
 *
 * Any other transition throws an Error.
 */

export const AttemptState = Object.freeze({
  PREPARING: 'PREPARING',
  LAUNCHING: 'LAUNCHING',
  STREAMING: 'STREAMING',
  SUCCEEDED: 'SUCCEEDED',
  FAILED: 'FAILED',
  TIMED_OUT: 'TIMED_OUT',
  STALLED: 'STALLED',
  CANCELED: 'CANCELED',
});

/** @type {Record<string, string[]>} */
const VALID_TRANSITIONS = {
  [AttemptState.PREPARING]: [AttemptState.LAUNCHING, AttemptState.CANCELED],
  [AttemptState.LAUNCHING]: [AttemptState.STREAMING],
  [AttemptState.STREAMING]: [
    AttemptState.SUCCEEDED,
    AttemptState.FAILED,
    AttemptState.TIMED_OUT,
    AttemptState.STALLED,
    AttemptState.CANCELED,
  ],
  [AttemptState.SUCCEEDED]: [],
  [AttemptState.FAILED]: [],
  [AttemptState.TIMED_OUT]: [],
  [AttemptState.STALLED]: [],
  [AttemptState.CANCELED]: [],
};

/**
 * Create an attempt lifecycle tracker.
 *
 * @param {string} ticketId
 * @param {string} stage
 * @param {number} attemptNumber   1-based attempt count
 * @returns {{ transition(newState: string): void, elapsed(clock: import('./ports.js').ClockPort): number, toJSON(): object }}
 */
export function createAttempt(ticketId, stage, attemptNumber) {
  let currentState = AttemptState.PREPARING;
  const startedAt = Date.now();

  return {
    /**
     * Transition to a new state.
     * Throws if the transition is not valid from the current state.
     *
     * @param {string} newState
     */
    transition(newState) {
      const allowed = VALID_TRANSITIONS[currentState];
      if (!allowed) {
        throw new Error(`Attempt ${ticketId}#${attemptNumber}: unknown current state '${currentState}'`);
      }
      if (!allowed.includes(newState)) {
        throw new Error(
          `Attempt ${ticketId}#${attemptNumber}: invalid transition ${currentState} → ${newState}. ` +
            `Allowed: [${allowed.join(', ')}]`,
        );
      }
      currentState = newState;
    },

    /**
     * Return elapsed milliseconds from startedAt to clock.now().
     *
     * @param {import('./ports.js').ClockPort} clock
     * @returns {number}
     */
    elapsed(clock) {
      return clock.now() - startedAt;
    },

    /**
     * Serialize to a plain object for persistence.
     *
     * @returns {object}
     */
    toJSON() {
      return {
        ticketId,
        stage,
        attempt: attemptNumber,
        state: currentState,
        startedAt,
      };
    },
  };
}
