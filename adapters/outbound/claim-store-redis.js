/**
 * claim-store-redis.js — Redis-backed ClaimPort for multi-container deployments.
 *
 * The claim store is the single source of truth for in-flight work — there is no
 * separate per-stage "processed" map. A claim exists only while a stage actively
 * processes a ticket; release() deletes it so the ticket is claimable (and thus
 * re-processable) again. The claim's only job is to stop concurrent pickup.
 *
 * Uses SET key value NX EX ttl for atomic claim acquisition — only one agent
 * across any number of containers can win the SETNX for a given ticket.
 *
 * Key format: autoframe:claim:{stage}:{ticketId}
 *   - stage namespaces claims so ENG-42 in "process" and "review" are independent
 *   - ticketId (e.g. "ENG-42") already includes the team prefix, so no teamKey needed
 *
 * Value format (running claim): JSON {"owner","startedAt"} so the scheduler can
 * detect stale tickets (agent died mid-stage) via listRunning(). A retry marker
 * ("retry:{ts}") is a non-JSON value and is excluded from listRunning().
 *
 * TTL is a generous backstop (LOCK_TTL_MULTIPLIER × stale_threshold_s) so a key
 * doesn't leak if the scheduler itself dies. Staleness is decided from startedAt,
 * NOT from TTL expiry — the lock must outlive the staleness window so the
 * scheduler can revert the Linear ticket before the lock is reclaimable.
 *
 * If Redis is unreachable, acquire() returns false (conservative — stall, don't double-work).
 */

import Redis from 'ioredis';

// Lua: delete the key only if its JSON value's owner matches ARGV[1]. Atomic.
// pcall guards non-JSON values (retry markers) so a stray release is a safe no-op.
const RELEASE_SCRIPT = `
  local v = redis.call("get", KEYS[1])
  if not v then return 0 end
  local ok, decoded = pcall(cjson.decode, v)
  if ok and decoded.owner == ARGV[1] then
    return redis.call("del", KEYS[1])
  end
  return 0
`;

// Lua: update lastHeartbeat in the JSON value and refresh the TTL, only if the
// stored owner matches ARGV[1]. ARGV[2]=ts(ms), ARGV[3]=TTL(s). Refreshing TTL
// on each heartbeat keeps a live agent's claim alive past the stale threshold so
// the dispatch pass never sees isOwned=false and re-acquires (double-execution).
const HEARTBEAT_SCRIPT = `
  local v = redis.call("get", KEYS[1])
  if not v then return 0 end
  local ok, decoded = pcall(cjson.decode, v)
  if not ok then return 0 end
  if decoded.owner ~= ARGV[1] then return 0 end
  decoded.lastHeartbeat = tonumber(ARGV[2])
  redis.call("set", KEYS[1], cjson.encode(decoded), "EX", tonumber(ARGV[3]))
  return 1
`;

const LOCK_TTL_MULTIPLIER = 2;
const KEY_PREFIX = 'autoframe:claim';

/**
 * @param {{
 *   redisUrl?: string,
 *   client?: import('ioredis').Redis,
 *   clock?: { now(): number },
 *   defaultTtlSeconds?: number
 * }} opts
 * @returns {import('../../core/ports.js').ClaimPort & { quit(): Promise<void> }}
 */
export function createRedisClaimStore({
  redisUrl,
  client,
  clock = { now: () => Date.now() },
  defaultTtlSeconds = 3600,
} = {}) {
  const redis =
    client ??
    new Redis(redisUrl, {
      lazyConnect: true,
      maxRetriesPerRequest: 2,
      enableReadyCheck: false,
    });

  redis.on('error', (err) => {
    console.error(`[claim-store-redis] Redis error: ${err.message}`);
  });

  function claimKey(stage, ticketId) {
    return `${KEY_PREFIX}:${stage}:${ticketId}`;
  }

  return {
    /**
     * Atomically acquire a claim. Returns false if already claimed or Redis is down.
     *
     * @param {string} ticketId
     * @param {string} owner
     * @param {string} [stage]
     * @param {number} [ttlSeconds]   stale threshold; key TTL is a multiple of this
     * @returns {Promise<boolean>}
     */
    async acquire(ticketId, owner, stage = 'unknown', ttlSeconds = defaultTtlSeconds) {
      try {
        const value = JSON.stringify({ owner, startedAt: clock.now() });
        const lockTtl = Math.ceil(ttlSeconds * LOCK_TTL_MULTIPLIER);
        const result = await redis.set(claimKey(stage, ticketId), value, 'NX', 'EX', lockTtl);
        return result === 'OK';
      } catch (err) {
        console.error(`[claim-store-redis] acquire failed for ${ticketId}: ${err.message}`);
        return false;
      }
    },

    /**
     * Release a claim only if this owner holds it (atomic Lua script).
     *
     * @param {string} ticketId
     * @param {string} owner
     * @param {string} [stage]
     * @returns {Promise<void>}
     */
    async release(ticketId, owner, stage = 'unknown') {
      try {
        await redis.eval(RELEASE_SCRIPT, 1, claimKey(stage, ticketId), owner);
      } catch (err) {
        console.error(`[claim-store-redis] release failed for ${ticketId}: ${err.message}`);
      }
    },

    /**
     * Check whether any owner holds a claim on this ticket in stage.
     *
     * @param {string} ticketId
     * @param {string} [stage]
     * @returns {Promise<boolean>}
     */
    async isOwned(ticketId, stage = 'unknown') {
      try {
        const exists = await redis.exists(claimKey(stage, ticketId));
        return exists === 1;
      } catch (err) {
        console.error(`[claim-store-redis] isOwned failed for ${ticketId}: ${err.message}`);
        return false;
      }
    },

    /**
     * List tickets currently Running in stage, with their startedAt. Used for the
     * concurrency count and stale-revert. Retry markers (non-JSON values) are
     * excluded — they are not occupying a concurrency slot. On Redis error, returns
     * [] (conservative — treat as nothing running rather than crash the tick).
     *
     * @param {string} stage
     * @returns {Promise<{ ticketId: string, startedAt: number, owner: string }[]>}
     */
    async listRunning(stage) {
      const results = [];
      const prefix = `${KEY_PREFIX}:${stage}:`;
      const pattern = `${prefix}*`;
      try {
        let cursor = '0';
        do {
          const [next, keys] = await redis.scan(cursor, 'MATCH', pattern, 'COUNT', 100);
          cursor = next;
          for (const key of keys) {
            const raw = await redis.get(key);
            if (raw === null) continue;
            let parsed;
            try {
              parsed = JSON.parse(raw);
            } catch {
              continue; // retry marker or malformed — not a running claim
            }
            if (typeof parsed.startedAt !== 'number') continue;
            results.push({
              ticketId: key.slice(prefix.length),
              startedAt: parsed.startedAt,
              owner: parsed.owner,
              lastHeartbeat: parsed.lastHeartbeat,
            });
          }
        } while (cursor !== '0');
      } catch (err) {
        console.error(`[claim-store-redis] listRunning failed for stage ${stage}: ${err.message}`);
      }
      return results;
    },

    /**
     * Update lastHeartbeat in the claim value and refresh the TTL. No-op if
     * the key is missing or the stored owner does not match (safe to call
     * unconditionally). Errors are swallowed so a Redis blip can't kill the
     * agent's readline loop (the caller does .catch(() => {})).
     *
     * @param {string} ticketId
     * @param {string} owner
     * @param {string} [stage]
     * @param {number} [ts]          ms epoch
     * @param {number} [ttlSeconds]  stale threshold; actual TTL is 2×
     * @returns {Promise<void>}
     */
    async heartbeat(ticketId, owner, stage = 'unknown', ts = 0, ttlSeconds = defaultTtlSeconds) {
      try {
        const lockTtl = Math.ceil(ttlSeconds * LOCK_TTL_MULTIPLIER);
        await redis.eval(HEARTBEAT_SCRIPT, 1, claimKey(stage, ticketId), owner, ts, lockTtl);
      } catch (err) {
        console.error(`[claim-store-redis] heartbeat failed for ${ticketId}: ${err.message}`);
      }
    },

    /**
     * Phase 3 stub — mark ticket for retry at retryAt timestamp.
     * Stores a non-JSON retry marker; TTL is time until retryAt.
     *
     * @param {string} ticketId
     * @param {number} retryAt
     * @param {string} [stage]
     * @returns {Promise<void>}
     */
    async queueRetry(ticketId, retryAt, stage = 'unknown') {
      try {
        const ttl = Math.max(1, Math.ceil((retryAt - clock.now()) / 1000));
        await redis.set(claimKey(stage, ticketId), `retry:${retryAt}`, 'EX', ttl);
      } catch (err) {
        console.error(`[claim-store-redis] queueRetry failed for ${ticketId}: ${err.message}`);
      }
    },

    /**
     * Clean up the Redis connection on shutdown.
     */
    async quit() {
      await redis.quit();
    },
  };
}
