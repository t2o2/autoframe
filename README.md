# Autonomous Agents

A self-contained template that wires Claude CLI to Linear for end-to-end autonomous ticket processing — from implementation through code review through merge.

## The Pipeline

```
Todo / Changes Required  →  autonomous-agent.sh        →  /ticket-process  →  In Review
In Review               →  autonomous-review-agent.sh  →  /ticket-review   →  Human Review / Changes Required
Merging                 →  autonomous-approve-agent.sh →  /ticket-approve  →  Done
```

Each script runs independently and polls Linear for tickets in its target state. All three can run simultaneously in separate terminals.

## Prerequisites

- **Claude CLI** — `npm install -g @anthropic-ai/claude-code` then `claude login`
- **wtp** — git worktree helper, install from https://github.com/nicholasgasior/wtp (optional — scripts fall back to plain `git worktree` commands if not found)
- **Linear API key** — create one at https://linear.app/settings/api with Issues read+write scope
- `git`, `curl`, `python3` — standard Unix tools

## Linear Setup

The following workflow states must exist in your Linear team. Create them under **Settings → Workflow**:

| State | Used by |
|---|---|
| **Todo** | autonomous-agent.sh picks up tickets from here |
| **In Progress** | agent sets this while implementing |
| **In Review** | agent sets this after pushing; review-agent picks up from here |
| **Human Review** | review-agent sets this on PASS; human verifies then moves to Merging |
| **Merging** | human sets this to trigger approve-agent |
| **Done** | approve-agent sets this after merge |
| **Changes Required** | review-agent sets this on FAIL; agent picks up again |

## Quick Start

```bash
git clone <repo> && cd autonomous-agents
./setup.sh
```

The setup script writes your Linear API key and team key to `.auto-claude/.env`, then optionally copies the scripts and Claude commands into an existing project.

Once configured, run each agent in a separate terminal from your project root:

```bash
./scripts/autonomous-agent.sh
./scripts/autonomous-review-agent.sh
./scripts/autonomous-approve-agent.sh
```

Each script accepts `--poll-interval <seconds>`, `--once` (process one ticket and exit), and `--reset` (clear the session cache).

## Running in Parallel

Multiple instances of each script can run concurrently against the same Linear team — per-ticket `mkdir` locks prevent two agents from processing the same ticket simultaneously. The lock directory name includes the ticket ID (`/tmp/agent-lock-TICKET-XX`).

If an agent crashes mid-ticket, the stale lock directory must be removed manually before that ticket will be picked up again. Replace `TEAMKEY` with your team key:

```bash
rm -rf /tmp/agent-lock-TEAMKEY-* /tmp/review-lock-TEAMKEY-* /tmp/approve-lock-TEAMKEY-*
```

## CLAUDE.md

The agents run Claude CLI against your repo. Claude automatically loads your project's `CLAUDE.md` as context for every ticket. Add one to your project root describing:

- Your tech stack and language versions
- Key architectural patterns and conventions
- How to run tests and lint
- Important directories and their purposes
- Any project-specific rules the agent should follow

A well-written `CLAUDE.md` dramatically improves implementation quality — the agent uses it to make technology-appropriate decisions without hallucinating your stack.

## What Each Command Does

### `/ticket-process <TICKET-ID>`

Picks up a ticket from Linear and implements it end-to-end:

1. Creates an isolated git worktree (`feat/<TICKET>` or `fix/<TICKET>`)
2. Fetches and analyzes the ticket; claims it (In Progress) with a plan comment
3. Explores the codebase and plans the implementation
4. Implements using TDD (red → green → refactor), all changes in the worktree
5. Runs the project's test suite
6. Captures visual proof (screenshots or API responses) and uploads to Linear
7. Commits, pushes the branch, and moves the ticket to In Review

The worktree is kept after the command completes — the review agent reuses it.

### `/ticket-review <TICKET-ID>`

Reviews a completed ticket branch:

1. Finds the implementation branch from the Linear comments
2. Reuses the existing worktree (no new checkout needed)
3. Runs a code review via an Explore agent scoped to changed files
4. Runs all applicable test suites; writes missing tests if gaps are found
5. Captures review proof and uploads to Linear
6. Posts a structured review comment (test table, inline screenshots, code concerns)
7. PASS → moves to Human Review; FAIL → moves to Changes Required

### `/ticket-approve <TICKET-ID>`

Merges an approved ticket:

1. Resolves the branch (`feat/` or `fix/`) and merge target (main branch, or parent ticket's branch for sub-tickets)
2. Fetches and safety-checks both branches
3. Rebases the ticket branch onto the target, then fast-forward merges
4. Pushes the target branch to origin (verified)
5. Moves the Linear ticket to Done with a merge summary comment
6. Removes the worktree and deletes the branch locally and remotely

## Worktree Layout

All worktrees live one level above your project root by default:

```
your-project/           # main repo
../worktrees/
  feat/TICKET-15/       # implementation + review worktree
  feat/TICKET-16/
```

The `wtp` helper manages this. If not installed, the scripts fall back to `git worktree add/remove` directly.

## Environment Variables

| Variable | Source | Description |
|---|---|---|
| `LINEAR_API_KEY` | `.auto-claude/.env` or shell env | Linear personal API key |
| `LINEAR_TEAM_KEY` | `.auto-claude/.env` or shell env | Linear team identifier (e.g. `ENG`) |

Both variables can be set in the environment before running the scripts, or stored in `.auto-claude/.env` (created by `setup.sh`).

## Logs

Each agent writes structured session logs alongside the scripts:

```
scripts/
  autonomous-agent-logs/agent.log
  autonomous-review-logs/agent.log
  autonomous-approve-logs/agent.log
```

Per-ticket raw Claude stream-json is written to the same directories with filenames like `TICKET-15-20260101-120000.log`. The stream-json log is parsed after each ticket to generate a per-phase summary printed to the terminal.
