/**
 * Port interfaces for the autoframe engine.
 * These are JSDoc-only type definitions — no runtime code.
 */

/**
 * @typedef {Object} Ticket
 * @property {string} id          Linear identifier e.g. "ENG-42"
 * @property {number} priority    Linear: 1=urgent,2=high,3=medium,4=low,0=none
 * @property {string} createdAt   ISO string (empty string if missing)
 * @property {string} state       current state name
 */

/**
 * @typedef {Object} StageConfig
 * @property {string}   name
 * @property {string[]} poll
 * @property {string}   claim
 * @property {string}   done
 * @property {string}   revert
 * @property {string}   command
 * @property {string}   [pass_state]
 * @property {string}   [fail_state]
 * @property {number}   stale_threshold_s
 */

/**
 * @typedef {Object} TrackerPort
 * @property {(stage: StageConfig) => Promise<Ticket[]>} fetchCandidates
 * @property {(ticketId: string, toState: string) => Promise<void>} claimTicket
 * @property {(ticketId: string, toState: string) => Promise<void>} revertTicket
 * @property {(ticketId: string) => Promise<string>} getState
 */

/**
 * @typedef {Object} AgentPort
 * @property {(opts: RunOpts) => Promise<AgentResult>} run
 */

/**
 * @typedef {Object} RunOpts
 * @property {string} command    e.g. "/ticket-process ENG-42"
 * @property {string} cwd
 * @property {number} attempt
 * @property {function(AgentEvent): void} onEvent
 */

/**
 * @typedef {Object} AgentResult
 * @property {number} exitCode
 * @property {string|undefined} verdict   "DONE"|"PASS"|"FAIL"|undefined
 */

/**
 * @typedef {{ kind: 'phase', title: string }
 *         | { kind: 'tool', name: string, hint?: string }
 *         | { kind: 'text', text: string }
 *         | { kind: 'error', message: string }
 *         | { kind: 'tokens', input: number, output: number, total: number }} AgentEvent
 */

/**
 * ClaimPort — single source of truth for in-flight work. A claim exists only
 * while a stage is actively processing a ticket; release() deletes it so the
 * ticket can be processed again. Claims are namespaced by stage.
 *
 * @typedef {Object} ClaimPort
 * @property {(ticketId: string, owner: string, stage?: string, ttlSeconds?: number) => Promise<boolean>} acquire   returns false if already claimed
 * @property {(ticketId: string, owner: string, stage?: string) => Promise<void>} release
 * @property {(ticketId: string, stage?: string) => Promise<boolean>} isOwned
 * @property {(ticketId: string, retryAt: number, stage?: string) => Promise<void>} queueRetry
 * @property {(stage: string) => Promise<{ ticketId: string, startedAt: number, owner: string, lastHeartbeat?: number }[]>} listRunning   Running claims only (excludes retry-queued); owner identifies the holding container
 * @property {(ticketId: string, owner: string, stage: string, ts: number, ttlSeconds: number) => Promise<void>} heartbeat   Update liveness timestamp; refreshes Redis TTL so a live agent never loses its claim to expiry
 */

/**
 * @typedef {Object} ClockPort
 * @property {() => number} now   returns Date.now() equivalent (milliseconds)
 */
