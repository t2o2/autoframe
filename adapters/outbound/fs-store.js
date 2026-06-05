/**
 * fs-store.js — StorePort: heartbeat/attempt records persisted to /tmp.
 *
 * Heartbeat files:  /tmp/<stage>-heartbeat-<ticketId>.json
 * Attempt files:    /tmp/<stage>-attempt-<ticketId>.json
 *
 * All errors are caught and logged; never throws to the caller.
 */

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const TMP_DIR = '/tmp';

/**
 * Create a filesystem-backed StorePort.
 *
 * @param {{ tmpDir?: string }} [opts]
 * @returns {import('../../core/ports.js').StorePort}
 */
export function createFsStore(opts = {}) {
  const tmpDir = opts.tmpDir ?? TMP_DIR;

  function heartbeatPath(ticketId, stage) {
    return join(tmpDir, `${stage}-heartbeat-${ticketId}.json`);
  }

  function attemptPath(ticketId, stage) {
    return join(tmpDir, `${stage}-attempt-${ticketId}.json`);
  }

  return {
    writeHeartbeat(ticketId, stage, data) {
      try {
        writeFileSync(heartbeatPath(ticketId, stage), JSON.stringify(data), 'utf8');
      } catch (err) {
        console.warn(`[fs-store] writeHeartbeat failed for ${ticketId}/${stage}: ${err.message}`);
      }
    },

    readHeartbeat(ticketId, stage) {
      const path = heartbeatPath(ticketId, stage);
      if (!existsSync(path)) return null;
      try {
        return JSON.parse(readFileSync(path, 'utf8'));
      } catch (err) {
        console.warn(`[fs-store] readHeartbeat failed for ${ticketId}/${stage}: ${err.message}`);
        return null;
      }
    },

    writeAttempt(ticketId, stage, data) {
      try {
        writeFileSync(attemptPath(ticketId, stage), JSON.stringify(data), 'utf8');
      } catch (err) {
        console.warn(`[fs-store] writeAttempt failed for ${ticketId}/${stage}: ${err.message}`);
      }
    },

    listRunning(stage) {
      const results = [];
      try {
        const prefix = `${stage}-attempt-`;
        const files = readdirSync(tmpDir).filter(
          (f) => f.startsWith(prefix) && f.endsWith('.json'),
        );
        for (const file of files) {
          try {
            const raw = readFileSync(join(tmpDir, file), 'utf8');
            const data = JSON.parse(raw);
            results.push(data);
          } catch {
            // Skip unparseable files
          }
        }
      } catch (err) {
        console.warn(`[fs-store] listRunning failed for stage ${stage}: ${err.message}`);
      }
      return results;
    },
  };
}
