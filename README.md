# Autonomous Agents

A self-contained template that wires Claude CLI to Linear for end-to-end autonomous ticket processing — from implementation through code review through merge.

## The Pipeline

```
Todo                      →  autonomous-agent-research.sh  →  /ticket-research  →  Research Pending Approval
                                                                                           ↓ (human approves → Planning)
Planning                  →  autonomous-agent-plan.sh  →  /ticket-plan      →  Plan Pending Approval
                                                                                           ↓ (human approves → Plan Approved)
Plan Approved / Changes Required  →  autonomous-agent-process.sh   →  /ticket-process   →  Review Pending
Review Pending            →  autonomous-agent-review.sh    →  /ticket-review    →  Human Review / Changes Required
Merging                   →  autonomous-agent-approve.sh   →  /ticket-approve   →  Done
```

Each script runs independently and polls Linear for tickets in its target state. All five can run simultaneously as separate containers.

The research and planning stages each include a human checkpoint — after the agent posts its output, a human reviews and manually advances the ticket to the next state before the next agent picks it up.

## Prerequisites

- **Docker** and **Docker Compose** — all other tools (Claude CLI, Chromium, wtp, ImageMagick, Rust) are bundled in the image
- **Linear API key** — create one at https://linear.app/settings/api with Issues read+write scope
- **Git remote** — HTTPS (via `GITHUB_TOKEN`) or SSH (via mounted `~/.ssh`)
- **Claude credentials** — subscription OAuth token, Anthropic API key, or OpenRouter key (see [Auth](#auth))

## Linear Setup

The following workflow states must exist in your Linear team. Create them under **Settings → Workflow**:

| State | Used by |
|---|---|
| **Todo** | research-agent picks up tickets from here |
| **Research** | research-agent sets this while exploring |
| **Research Pending Approval** | research-agent sets this when done; human reviews and moves to Planning |
| **Planning** | planning-agent picks up from here |
| **Plan Pending Approval** | planning-agent sets this when done; human reviews and moves to Plan Approved |
| **Plan Approved** | coding-agent picks up from here |
| **In Progress** | coding-agent sets this while implementing |
| **Review Pending** | coding-agent sets this after pushing; review-agent polls this and claims by setting In Review |
| **In Review** | review-agent sets this while reviewing the ticket |
| **Human Review** | review-agent sets this on PASS; human verifies then moves to Merging |
| **Merging** | human sets this to trigger approve-agent |
| **Done** | approve-agent sets this after merge |
| **Changes Required** | review-agent sets this on FAIL; coding-agent picks up again |

If you want to skip the research/planning stages, move tickets directly to **Plan Approved** and run only the `process`, `review`, and `approve` profiles.

## Quick Start

**1. Configure your environment**

```bash
cp .env.example .env
# Edit .env — fill in LINEAR_API_KEY, LINEAR_TEAM_KEY, GIT_REPO_URL, GITHUB_TOKEN,
# and your chosen API credentials (see Auth section below)
```

**2. Build the image**

```bash
docker compose build
```

**3. Start agents**

Run all five agents:

```bash
docker compose --profile all up -d
```

Or start individual agents:

```bash
docker compose --profile research up -d   # researches Todo tickets
docker compose --profile plan up -d       # plans Research Pending Approval → Planning tickets
docker compose --profile process up -d    # implements Plan Approved + Changes Required tickets
docker compose --profile review up -d     # reviews Review Pending tickets
docker compose --profile approve up -d    # merges Merging tickets
```

On first start each container clones `GIT_REPO_URL` fresh into `/workspace/repo`. Branches are pushed back to the remote — the host filesystem is never touched.

## Auth

Three credential modes are supported; the container auto-detects which to use:

| Mode | How | Cost |
|---|---|---|
| **Claude subscription** (default) | Mount `~/.claude` from host (docker-compose.yml does this automatically) — no keys needed | Subscription |
| **Anthropic API key** | Set `ANTHROPIC_API_KEY` in `.env` | Per token |
| **OpenRouter** | Set `OPENROUTER_API_KEY` and `OR_MODEL` in `.env` | Per token |

Priority order inside the container: `CLAUDE_CODE_OAUTH_TOKEN` → `ANTHROPIC_API_KEY` → `OPENROUTER_API_KEY`.

## Running in Parallel

Multiple containers of the same agent type can run concurrently — per-ticket `mkdir` locks prevent two agents from processing the same ticket simultaneously.

```bash
# Run three process agents in parallel
docker compose --profile process up -d --scale process=3
```

If an agent crashes mid-ticket, the stale lock directory must be removed before that ticket will be picked up again:

```bash
docker compose exec process rm -rf /tmp/process-lock-*
# or for other agents:
docker compose exec research rm -rf /tmp/research-lock-*
docker compose exec plan     rm -rf /tmp/plan-lock-*
docker compose exec review   rm -rf /tmp/review-lock-*
docker compose exec approve  rm -rf /tmp/approve-lock-*
```

## CLAUDE.md

The agents run Claude CLI against your repo. Claude automatically loads your project's `CLAUDE.md` as context for every ticket. Add one to your project root describing:

- Your tech stack and language versions
- Key architectural patterns and conventions
- How to run tests and lint
- Important directories and their purposes
- Any project-specific rules the agent should follow

Your host `~/.claude/CLAUDE.md` is also forwarded into the container and merged with the project-level file.

A well-written `CLAUDE.md` dramatically improves implementation quality — the agent uses it to make technology-appropriate decisions without hallucinating your stack.

## Logs

Each agent writes structured session logs inside the container:

```
scripts/
  autonomous-research-logs/agent.log
  autonomous-plan-logs/agent.log
  autonomous-process-logs/agent.log
  autonomous-review-logs/agent.log
  autonomous-approve-logs/agent.log
```

Follow live logs with Docker Compose:

```bash
docker compose logs -f process    # tail process agent
docker compose logs -f            # tail all agents
```

Per-ticket raw Claude stream-json is written to the same directories with filenames like `TICKET-15-20260101-120000.log`. The stream-json log is parsed after each ticket to generate a per-phase summary printed to the terminal.

## What Each Command Does

### `/ticket-research <TICKET-ID>`

Researches a ticket by exploring the codebase and posting findings as a ticket comment:

1. Fetches ticket details and sets status to `Research`
2. Decomposes the ticket into research areas
3. Spawns parallel `Explore` agents — one per area (scope, patterns, tests, schema)
4. Synthesizes findings into a structured research document with file:line references
5. Posts the document as a ticket comment and moves to `Research Pending Approval`

No code changes are made — this is a read-only codebase pass.

### `/ticket-plan <TICKET-ID>`

Creates a phased implementation plan from the ticket and its research comment:

1. Fetches ticket details and extracts the research comment (if present)
2. Spawns `Explore` agents to fill any remaining gaps
3. Resolves architectural decisions; posts a comment if human judgment is needed
4. Writes a phased plan — each phase has explicit file changes and success criteria
5. Posts the plan as a ticket comment and moves to `Plan Pending Approval`

No code changes are made — this is a planning-only pass.

### `/ticket-process <TICKET-ID>`

Picks up a ticket from Linear and implements it end-to-end:

1. Creates an isolated git worktree (`feat/<TICKET>` or `fix/<TICKET>`)
2. Fetches and analyzes the ticket; claims it (In Progress) with a plan comment
3. Explores the codebase and plans the implementation
4. Implements using TDD (red → green → refactor), all changes in the worktree
5. Runs the project's test suite
6. Captures visual proof (screenshots or API responses) and uploads to Linear
7. Commits, pushes the branch, and moves the ticket to Review Pending

The worktree is kept after the command completes — the review agent reuses it.

### `/ticket-review <TICKET-ID>`

Reviews a completed ticket branch (input state: Review Pending):

1. Claims the ticket by setting it to In Review
2. Finds the implementation branch from the Linear comments
3. Reuses the existing worktree (no new checkout needed)
4. Runs a code review via an Explore agent scoped to changed files
5. Runs all applicable test suites; writes missing tests if gaps are found
6. Captures review proof and uploads to Linear
7. Posts a structured review comment (test table, inline screenshots, code concerns)
8. PASS → moves to Human Review; FAIL → moves to Changes Required

### `/ticket-approve <TICKET-ID>`

Merges an approved ticket:

1. Resolves the branch (`feat/` or `fix/`) and merge target (main branch, or parent ticket's branch for sub-tickets)
2. Fetches and safety-checks both branches
3. Rebases the ticket branch onto the target, then fast-forward merges
4. Pushes the target branch to origin (verified)
5. Moves the Linear ticket to Done with a merge summary comment
6. Removes the worktree and deletes the branch locally and remotely

## Worktree Layout

All worktrees live inside the container's workspace:

```
/workspace/
  repo/               # main clone (GIT_REPO_URL)
  repo/../worktrees/
    feat/TICKET-15/   # implementation + review worktree
    feat/TICKET-16/
```

Changes are committed and pushed to the remote — nothing is written to the host filesystem.

## Environment Variables

| Variable | Description |
|---|---|
| `GIT_REPO_URL` | Repository the container clones and works in (e.g. `https://github.com/org/repo.git`) |
| `GIT_BASE_BRANCH` | Branch to clone from (default: `develop`) |
| `GITHUB_TOKEN` | GitHub personal access token for HTTPS clone + push (needs `repo` + `workflow` scopes) |
| `LINEAR_API_KEY` | Linear personal API key |
| `LINEAR_TEAM_KEY` | Linear team identifier (e.g. `ENG`) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Long-lived Claude subscription token — from `claude setup-token` on host |
| `ANTHROPIC_API_KEY` | Direct Anthropic API key |
| `ANTHROPIC_BASE_URL` | Override API endpoint (e.g. a custom proxy) |
| `OPENROUTER_API_KEY` | OpenRouter API key (routed through a local compatibility proxy) |
| `OR_MODEL` | Model ID for OpenRouter (e.g. `deepseek/deepseek-r1`) |
| `DOCKER_PLATFORM` | Docker build platform — `arm64` for Apple Silicon, `amd64` for Intel/AMD |
| `DOCKER_TARGETARCH` | Matches `DOCKER_PLATFORM` — used for architecture-aware binary installs |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (from `@BotFather`) — enables human-in-the-loop input |
| `TELEGRAM_CHAT_ID` | Your Telegram chat or user ID |

All variables are read from `.env` (copy from `.env.example`).

### Telegram setup (optional — enables human-in-the-loop input)

When an agent needs a decision it can't resolve from code, it sends the question to Telegram and waits up to 1 hour for a reply before applying a default.

1. Message `@BotFather` → `/newbot` → copy the token
2. Start a chat with your bot, then get your chat ID:
   ```bash
   curl "https://api.telegram.org/bot<TOKEN>/getUpdates"
   # Look for "chat":{"id": ...} in the result
   ```
3. Add to `.env`:
   ```
   TELEGRAM_BOT_TOKEN=<token>
   TELEGRAM_CHAT_ID=<chat_id>
   ```

**Reply formats** — send in Telegram when asked:
- `2` — choose option 2
- `1,3` — choose options 1 and 3 (multi-select)
- `all` — choose all options
- `skip` — pass with no input
- any other text — treated as a free-text answer
