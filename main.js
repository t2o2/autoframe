#!/usr/bin/env node
/**
 * main.js — autoframe engine entry point.
 *
 * Wires dependencies and dispatches CLI commands.
 * Uses process.argv for argument parsing (no external arg-parser needed).
 */

import os from 'node:os';
import { parseArgs, printHelp } from './adapters/inbound/cli.js';
import { loadWorkflow } from './adapters/outbound/workflow-loader.js';

// Per-container identity: tags this container's claims so the concurrency cap is
// counted per-container (each container dispatches up to config.dispatch.concurrency).
// hostname is the container id in most orchestrators; pid disambiguates locally.
const OWNER = `${os.hostname()}:${process.pid}`;

const args = parseArgs(process.argv.slice(2));

switch (args.command) {
  case 'run':
    await runCommand(args);
    break;

  case 'status':
    await statusCommand();
    break;

  default:
    printHelp();
    process.exit(0);
}

/**
 * Handle `node main.js run --stage <name|all> [--dry-run]`
 *
 * @param {{ stage?: string, dryRun?: boolean }} opts
 */
async function runCommand({ stage, dryRun }) {
  if (!stage) {
    console.error('Error: --stage is required. Use --stage <name> or --stage all.');
    printHelp();
    process.exit(1);
  }

  const workflowPath = process.env.WORKFLOW_TOML;
  const config = loadWorkflow(workflowPath);

  if (!config) {
    console.error('Error: Could not load workflow.toml. Set WORKFLOW_TOML env var or place workflow.toml in /workspace/repo/.');
    process.exit(1);
  }

  let targetStages;
  if (stage === 'all') {
    targetStages = config.stages;
  } else {
    const found = config.stages.find((s) => s.name === stage);
    if (!found) {
      const names = config.stages.map((s) => s.name).join(', ');
      console.error(`Error: Stage '${stage}' not found. Available stages: ${names}`);
      process.exit(1);
    }
    targetStages = [found];
  }

  if (dryRun) {
    console.log('=== autoframe dry-run ===');
    console.log(`Stage(s): ${targetStages.map((s) => s.name).join(', ')}`);
    console.log(`Concurrency: ${config.dispatch.concurrency}`);
    console.log('');
    for (const s of targetStages) {
      console.log(`Stage: ${s.name}`);
      console.log(`  Poll states: ${s.poll.join(', ')}`);
      console.log(`  Claim state: ${s.claim}`);
      console.log(`  Done state:  ${s.done || '(none)'}`);
      console.log(`  Revert state: ${s.revert}`);
      console.log(`  Command:     ${s.command}`);
      if (s.pass_state) console.log(`  Pass state:  ${s.pass_state}`);
      if (s.fail_state) console.log(`  Fail state:  ${s.fail_state}`);
      console.log('');
    }
    console.log('Dry-run complete. No connections made.');
    process.exit(0);
  }

  const apiKey = process.env.LINEAR_API_KEY;
  const teamKey = process.env.LINEAR_TEAM_KEY;

  if (!apiKey || !teamKey) {
    console.error('Error: LINEAR_API_KEY and LINEAR_TEAM_KEY are required for live run.');
    console.error('Use --dry-run to test without credentials.');
    process.exit(1);
  }

  const { createLinearTracker } = await import('./adapters/outbound/linear-tracker.js');
  const { createClaudeAgent } = await import('./adapters/outbound/claude-agent.js');
  const { createScheduler } = await import('./core/scheduler.js');
  const { createPollDriver } = await import('./adapters/inbound/poll-driver.js');

  const tracker = createLinearTracker({ apiKey, teamKey });
  const agent = createClaudeAgent();

  const { claims, label } = await createClaims();
  console.log(`[autoframe] Claim store: ${label}`);
  console.log(`[autoframe] Container owner: ${OWNER}`);

  const clock = { now: () => Date.now() };
  const POLL_INTERVAL_MS = 60_000;

  const scheduler = createScheduler({
    tracker,
    agent,
    claims,
    clock,
    stages: targetStages,
    config,
    owner: OWNER,
  });

  console.log(`[autoframe] Starting engine for stage(s): ${targetStages.map((s) => s.name).join(', ')}`);
  console.log(`[autoframe] Poll interval: ${POLL_INTERVAL_MS / 1000}s`);

  const driver = createPollDriver({
    scheduler,
    pollIntervalMs: POLL_INTERVAL_MS,
  });

  async function shutdown(signal) {
    if (signal === 'SIGINT') console.log('');
    console.log('[autoframe] Shutting down...');
    driver.stop();
    if (claims.quit) await claims.quit();
    process.exit(0);
  }

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

/**
 * Construct the claim store: Redis when REDIS_URL is set (shared across
 * containers), otherwise an in-memory store for single-process mode.
 *
 * @returns {Promise<{ claims: import('./core/ports.js').ClaimPort & { quit?: () => Promise<void> }, label: string, shared: boolean }>}
 */
async function createClaims() {
  const redisUrl = process.env.REDIS_URL;
  if (redisUrl) {
    const { createRedisClaimStore } = await import('./adapters/outbound/claim-store-redis.js');
    return { claims: createRedisClaimStore({ redisUrl }), label: `Redis (${redisUrl})`, shared: true };
  }
  const { createClaimStore } = await import('./adapters/outbound/claim-store.js');
  return { claims: createClaimStore(), label: 'in-memory (single-agent mode)', shared: false };
}

/**
 * Handle `node main.js status` — reads running claims from the claim store.
 */
async function statusCommand() {
  const { loadWorkflow } = await import('./adapters/outbound/workflow-loader.js');

  const config = loadWorkflow(process.env.WORKFLOW_TOML);
  const stages = config?.stages?.map((s) => s.name) ?? [
    'research', 'plan', 'process', 'review', 'approve',
  ];

  const { claims, label, shared } = await createClaims();
  const now = Date.now();

  console.log('=== autoframe status ===');
  console.log(`Claim store: ${label}`);
  console.log('');

  if (!shared) {
    console.log('  In-memory claims are not visible across processes — set REDIS_URL to inspect a running engine.');
    console.log('');
    return;
  }

  let found = 0;
  for (const stageName of stages) {
    const running = await claims.listRunning(stageName);
    for (const record of running) {
      found++;
      const elapsedS = Math.floor((now - (record.startedAt ?? now)) / 1000);
      const elapsed = `${Math.floor(elapsedS / 60)}m${elapsedS % 60}s`;
      console.log(`  ${record.ticketId ?? '?'}  stage=${stageName}  owner=${record.owner ?? '?'}  elapsed=${elapsed}`);
    }
  }

  if (found === 0) {
    console.log('  No running tickets found.');
  }
  console.log('');

  if (claims.quit) await claims.quit();
}
