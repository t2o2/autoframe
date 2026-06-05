/**
 * claim-store-redis.js — Redis-backed ClaimPort for multi-container deployments.
 *
 * Uses SET key owner NX EX ttl for atomic claim acquisition — only one agent
 * across any number of containers can win the SETNX for a given ticket.
 *
 * Key format: autoframe:claim:{stage}:{ticketId}
 *   - stage namespaces claims so ENG-42 in "process" and "review" are independent
 *   - ticketId (e.g. "ENG-42") already includes the team prefix, so no teamKey needed
 *
 * TTL = stale_threshold_s from the stage config, passed via acquire().
 * If Redis is unreachable, acquire() returns false (conservative — stall, don't double-work).
 *
 * UNVERIFIED: needs live run with a Redis instance.
 */

import Redis from 'ioredis';

// Lua script: delete key only if its value matches owner. Atomic.
const RELEASE_SCRIPT = `
  if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
  else
    return 0
  end
`;

/**
 * @param {{ redisUrl: string, defaultTtlSeconds?: number }} opts
 * @returns {import('../../core/ports.js').ClaimPort & { quit(): Promise<void> }}
 */
export function createRedisClaimStore({ redisUrl, defaultTtlSeconds = 3600 }) {
  const client = new Redis(redisUrl, {
    lazyConnect: true,
    maxRetriesPerRequest: 2,
    enableReadyCheck: false,
  });

  client.on('error', (err) => {
    console.error(`[claim-store-redis] Redis error: ${err.message}`);
  });

  function claimKey(stage, ticketId) {
    return `autoframe:claim:${stage}:${ticketId}`;
  }

  return {
    /**
     * Atomically acquire a claim. Returns false if already claimed or Redis is down.
     *
     * @param {string} ticketId
     * @param {string} owner
     * @param {string} [stage]
     * @param {number} [ttlSeconds]
     * @returns {Promise<boolean>}
     */
    async acquire(ticketId, owner, stage = 'unknown', ttlSeconds = defaultTtlSeconds) {
      try {
        const result = await client.set(claimKey(stage, ticketId), owner, 'NX', 'EX', ttlSeconds);
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
        await client.eval(RELEASE_SCRIPT, 1, claimKey(stage, ticketId), owner);
      } catch (err) {
        console.error(`[claim-store-redis] release failed for ${ticketId}: ${err.message}`);
      }
    },

    /**
     * Check whether any owner holds a claim on this ticket.
     *
     * @param {string} ticketId
     * @param {string} [stage]
     * @returns {Promise<boolean>}
     */
    async isOwned(ticketId, stage = 'unknown') {
      try {
        const exists = await client.exists(claimKey(stage, ticketId));
        return exists === 1;
      } catch (err) {
        console.error(`[claim-store-redis] isOwned failed for ${ticketId}: ${err.message}`);
        return false;
      }
    },

    /**
     * Phase 3 stub — mark ticket for retry at retryAt timestamp.
     * Stores the retry time as the value; TTL is time until retryAt.
     *
     * @param {string} ticketId
     * @param {number} retryAt
     * @param {string} [stage]
     * @returns {Promise<void>}
     */
    async queueRetry(ticketId, retryAt, stage = 'unknown') {
      try {
        const ttl = Math.max(1, Math.ceil((retryAt - Date.now()) / 1000));
        await client.set(claimKey(stage, ticketId), `retry:${retryAt}`, 'EX', ttl);
      } catch (err) {
        console.error(`[claim-store-redis] queueRetry failed for ${ticketId}: ${err.message}`);
      }
    },

    /**
     * Clean up the Redis connection on shutdown.
     */
    async quit() {
      await client.quit();
    },
  };
}
