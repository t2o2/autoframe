/**
 * cli.js — command-line interface for the autoframe engine.
 *
 * Commands:
 *   node main.js run --stage <name|all> [--dry-run]
 *   node main.js status
 */

/**
 * Parse process.argv into a structured command object.
 *
 * @param {string[]} argv   process.argv slice (from index 2)
 * @returns {{ command: string, stage?: string, dryRun?: boolean }}
 */
export function parseArgs(argv) {
  const [command, ...rest] = argv;

  if (command === 'run') {
    let stage;
    let dryRun = false;
    for (let i = 0; i < rest.length; i++) {
      if (rest[i] === '--stage' && rest[i + 1]) {
        stage = rest[++i];
      } else if (rest[i] === '--dry-run') {
        dryRun = true;
      }
    }
    return { command: 'run', stage, dryRun };
  }

  if (command === 'status') {
    return { command: 'status' };
  }

  return { command: command ?? 'help' };
}

/**
 * Print usage information.
 */
export function printHelp() {
  console.log(`
autoframe — Node.js engine for autonomous Linear agent stages

Usage:
  node main.js run --stage <name|all> [--dry-run]
  node main.js status

Commands:
  run      Poll Linear and dispatch agent tasks for the given stage.
           --stage process   Run only the 'process' stage.
           --stage all       Run all stages with global concurrency cap.
           --dry-run         Print what would run; exit without connecting to Linear.

  status   Print running claims from the claim store (requires REDIS_URL).

Environment:
  WORKFLOW_TOML         Path to workflow.toml (optional; falls back to discovery)
  LINEAR_API_KEY        Linear personal API key (required for non-dry-run)
  LINEAR_TEAM_KEY       Linear team key e.g. ENG (required for non-dry-run)
  REDIS_URL             Redis connection for shared claims (optional; in-memory if unset)

  Feedback channel (at least one pair required):
  SLACK_BOT_TOKEN       Slack bot token   ┐ Slack is used when both are set.
  SLACK_CHANNEL         Slack channel ID  ┘ Takes priority over Telegram if both channels are configured.
  TELEGRAM_BOT_TOKEN    Telegram bot token   ┐ Telegram is used when both are set
  TELEGRAM_CHAT_ID      Telegram chat ID     ┘ and Slack credentials are absent.
`.trim());
}
