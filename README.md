# Autonomous Agents

A self-contained template that wires Claude CLI to Linear for end-to-end autonomous ticket processing — from implementation through code review through merge.

## The Pipeline

```
Todo                      →  autonomous-agent-research.sh  →  /ticket-research  →  Pending Research Approval
                                                                                           ↓ (human approves → Planning)
Planning                  →  autonomous-agent-plan.sh  →  /ticket-plan      →  Pending Plan Approval
                                                                                           ↓ (human approves → Plan Approved)
Plan Approved / Changes Required  →  autonomous-agent-process.sh   →  /ticket-process   →  In Review
In Review                 →  autonomous-agent-review.sh    →  /ticket-review    →  Human Review / Changes Required
Merging                   →  autonomous-agent-approve.sh   →  /ticket-approve   →  Done
```

Each script runs independently and polls Linear for tickets in its target state. All five can run simultaneously in separate terminals.

The research and planning stages each include a human checkpoint — after the agent posts its output, a human reviews and manually advances the ticket to the next state before the next agent picks it up.

## Prerequisites

- **Claude CLI** — `npm install -g @anthropic-ai/claude-code` then `claude login`
- **wtp** — git worktree helper, install from https://github.com/nicholasgasior/wtp (optional — scripts fall back to plain `git worktree` commands if not found)
- **Linear API key** — create one at https://linear.app/settings/api with Issues read+write scope
- `git`, `curl`, `python3` — standard Unix tools

## Linear Setup

The following workflow states must exist in your Linear team. Create them under **Settings → Workflow**:

| State | Used by |
|---|---|
| **Todo** | research-agent picks up tickets from here |
| **Research** | research-agent sets this while exploring |
| **Pending Research Approval** | research-agent sets this when done; human reviews and moves to Planning |
| **Planning** | planning-agent picks up from here |
| **Pending Plan Approval** | planning-agent sets this when done; human reviews and moves to Plan Approved |
| **Plan Approved** | coding-agent picks up from here |
| **In Progress** | coding-agent sets this while implementing |
| **In Review** | coding-agent sets this after pushing; review-agent picks up from here |
| **Human Review** | review-agent sets this on PASS; human verifies then moves to Merging |
| **Merging** | human sets this to trigger approve-agent |
| **Done** | approve-agent sets this after merge |
| **Changes Required** | review-agent sets this on FAIL; coding-agent picks up again |

If you want to skip the research/planning stages and use only the original three agents, simply move tickets directly to **Plan Approved** or **In Progress** and only run `autonomous-agent-process.sh`, `autonomous-agent-review.sh`, and `autonomous-agent-approve.sh`.

## Quick Start

Run this from inside your existing repo:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/t2o2/autoframe/master/setup.sh)
```

The setup script writes your Linear API key and team key to `.auto-claude/.env`, then optionally copies the scripts and Claude commands into an existing project.

Once configured, run each agent in a separate terminal from your project root:

```bash
./scripts/autonomous-agent-research.sh   # researches Todo tickets
./scripts/autonomous-agent-plan.sh   # plans Pending Research Approval → Planning tickets
./scripts/autonomous-agent-process.sh            # implements Plan Approved + Changes Required tickets
./scripts/autonomous-agent-review.sh     # reviews In Review tickets
./scripts/autonomous-agent-approve.sh    # merges Merging tickets
```

Each script accepts `--poll-interval <seconds>`, `--once` (process one ticket and exit), and `--reset` (clear the session cache).

## Running in Parallel

Multiple instances of each script can run concurrently against the same Linear team — per-ticket `mkdir` locks prevent two agents from processing the same ticket simultaneously.

If an agent crashes mid-ticket, the stale lock directory must be removed manually before that ticket will be picked up again:

```bash
rm -rf /tmp/research-lock-* /tmp/planning-lock-* /tmp/agent-lock-* /tmp/review-lock-* /tmp/approve-lock-*
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

### `/ticket-research <TICKET-ID>`

Researches a ticket by exploring the codebase and posting findings as a ticket comment:

1. Fetches ticket details and sets status to `Research`
2. Decomposes the ticket into research areas
3. Spawns parallel `Explore` agents — one per area (scope, patterns, tests, schema)
4. Synthesizes findings into a structured research document with file:line references
5. Posts the document as a ticket comment and moves to `Pending Research Approval`

No code changes are made — this is a read-only codebase pass.

### `/ticket-plan <TICKET-ID>`

Creates a phased implementation plan from the ticket and its research comment:

1. Fetches ticket details and extracts the research comment (if present)
2. Spawns `Explore` agents to fill any remaining gaps
3. Resolves architectural decisions; posts a comment if human judgment is needed
4. Writes a phased plan — each phase has explicit file changes and success criteria
5. Posts the plan as a ticket comment and moves to `Pending Plan Approval`

No code changes are made — this is a planning-only pass.

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
