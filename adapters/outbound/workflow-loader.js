/**
 * workflow-loader.js — parse workflow.toml and validate with zod.
 *
 * Discovery order (matches scripts/lib/workflow-loader.sh):
 *   1. WORKFLOW_TOML env var (explicit override)
 *   2. /workspace/repo/workflow.toml (target repo inside container)
 *   3. Bundled default: ../../workflow.toml relative to this file (dev: repo root)
 *
 * Returns a validated config object or null on any error.
 * Never throws — Symphony's graceful degradation rule.
 */

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname, resolve } from 'node:path';
import { parse as parseTOML } from 'smol-toml';
import { z } from 'zod';

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Zod schema for a single stage entry.
 *
 * Matching the real workflow.toml structure:
 *   - done/pass_state/fail_state can be empty strings (e.g. review.done="", all non-review pass/fail="")
 *   - linear_stale_threshold_s can be empty string (approve stage) or a number
 */
const StageSchema = z.object({
  name: z.string().min(1),
  poll: z.array(z.string().min(1)),
  claim: z.string().min(1),
  done: z.string(),
  revert: z.string().min(1),
  command: z.string().min(1),
  pass_state: z.string().optional().default(''),
  fail_state: z.string().optional().default(''),
  lock_prefix: z.string().min(1),
  stage_verb: z.string().min(1),
  watch_states: z.array(z.string()),
  stale_threshold_s: z.number(),
  linear_stale_threshold_s: z.union([z.number(), z.literal('')]),
});

const WorkflowSchema = z.object({
  tracker: z.object({
    type: z.string().min(1),
    team: z.string().min(1),
  }),
  defaults: z.object({
    agent: z.string().min(1),
    timeout_silent_s: z.number().optional(),
    timeout_tracker_s: z.number().optional(),
    workspace_root: z.string().min(1),
  }),
  dispatch: z.object({
    order: z.array(z.string()),
    concurrency: z.number().int().positive(),
  }),
  stages: z.array(StageSchema).min(1),
  preamble: z
    .object({
      text: z.string(),
    })
    .optional(),
});

/**
 * Locate the workflow.toml file using the same discovery order as workflow-loader.sh.
 * When an explicit path is provided (via argument or WORKFLOW_TOML env), only that
 * path is checked — no fallback discovery. This matches the bash loader's behavior
 * where $WORKFLOW_TOML is a hard override with no fallback.
 *
 * @param {string|undefined} explicitPath  explicit path from arg or WORKFLOW_TOML env
 * @returns {string|null}
 */
function findTomlPath(explicitPath) {
  if (explicitPath) {
    return existsSync(explicitPath) ? explicitPath : null;
  }

  const containerPath = '/workspace/repo/workflow.toml';
  if (existsSync(containerPath)) {
    return containerPath;
  }

  const bundledPath = resolve(__dirname, '../../workflow.toml');
  if (existsSync(bundledPath)) {
    return bundledPath;
  }

  return null;
}

/**
 * Load and validate workflow.toml.
 *
 * @param {string} [tomlPath]   explicit path; falls back to discovery order
 * @returns {z.infer<typeof WorkflowSchema>|null}
 */
export function loadWorkflow(tomlPath) {
  const discovered = findTomlPath(tomlPath ?? process.env.WORKFLOW_TOML);

  if (!discovered) {
    console.warn('[workflow-loader] WARN: workflow.toml not found — no workflow loaded');
    return null;
  }

  let raw;
  try {
    raw = readFileSync(discovered, 'utf8');
  } catch (err) {
    console.warn(`[workflow-loader] WARN: Cannot read ${discovered}: ${err.message}`);
    return null;
  }

  let parsed;
  try {
    parsed = parseTOML(raw);
  } catch (err) {
    console.warn(`[workflow-loader] WARN: TOML parse error in ${discovered}: ${err.message}`);
    return null;
  }

  const result = WorkflowSchema.safeParse(parsed);
  if (!result.success) {
    console.warn(`[workflow-loader] WARN: Schema validation failed: ${result.error.message}`);
    return null;
  }

  return result.data;
}

export { WorkflowSchema, StageSchema };
