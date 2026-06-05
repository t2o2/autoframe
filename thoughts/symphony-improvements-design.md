# Autoframe — Symphony-Inspired Improvements: Design

> Design for the improvements raised in the Symphony vs autoframe comparison.
> Status: proposal. No code changed yet.

## Problem statement

Autoframe's behavior lives in **~7,500 lines of bash across 10 near-identical scripts**
(`scripts/autonomous-agent-{research,plan,process,review,approve}{,-pi}.sh`). Each script is
685–976 lines and ~90% boilerplate — heartbeat, watchdogs, stale-claim recovery, Linear
GraphQL, stream parsing, the poll loop. The only real per-script deltas are:

| Knob | `process.sh` value |
|---|---|
| Poll filter states | `Plan Approved`, `Changes Required` |
| Claimed (in-flight) state | `In Progress` |
| Success handoff state | `Review Pending` |
| Revert-on-failure state | `Plan Approved` |
| Status-watcher allowed states | `Plan Approved:Changes Required:In Progress` |
| Slash command | `/ticket-process` |
| lock / heartbeat / cache prefix | `process` |
| Agent binary | `claude` vs `pi` |

Everything else is copy-paste. All of those knobs are **hardcoded in bash** — state names are
baked directly into GraphQL query strings (`autonomous-agent-process.sh:305`), branch
conventions and test commands into the slash-command prompts. Symphony's lesson is to pull that
whole contract out into **one versioned, per-repo file** and run **one engine** against it.

This design covers all raised improvements, grouped by leverage.

---

## Tier 1 — Externalize the contract + collapse duplication

This is the root fix. Three pieces: a config contract (1A), one engine that reads it (1B), and a
swappable agent adapter (1C). Together they replace the 10 scripts with **one engine + one config
file + N thin adapters**.

The architecture follows the house style in `~/.claude/CLAUDE.md` (hexagonal, ports/adapters,
zero-dep core, zod at boundaries, TDD):

```
core/                      # pure domain, zero deps, 100% unit-tested with fakes
  scheduler.ts             # reconcile → fetch → sort → dispatch state machine
  claim.ts                 # claim model: Unclaimed → Claimed{Running|RetryQueued} → Released
  attempt.ts               # run-attempt lifecycle + stall/timeout policy
  retry.ts                 # backoff policy (Tier 3C)
  dispatch.ts              # ordering policy (Tier 2)
  ports.ts                 # TrackerPort, AgentPort, ClaimPort, StorePort, ClockPort, HooksPort
adapters/
  inbound/
    poll-driver.ts         # the loop that ticks the scheduler
    http-dashboard.ts      # snapshot API + status page (Tier 3A)
    cli.ts                 # `autoframe run --stage process`, `autoframe status`
  outbound/
    linear-tracker.ts      # GraphQL TrackerPort impl
    claude-agent.ts        # AgentPort impl (stream-json)
    pi-agent.ts            # AgentPort impl (pi)
    codex-agent.ts         # AgentPort impl (Codex App Server — Symphony interop, future)
    fs-store.ts            # intra-container heartbeat/attempt records (today's /tmp files)
    claim-store.ts         # cross-container claim authority — tracker-atomic or Redis (see Claim model)
    workflow-loader.ts     # parse + zod-validate WORKFLOW.md
main.ts                    # wiring / DI
```

Runtime: **plain ESM Node (`node:22`)** — no build step. This is an infra tool that ships scripts
which run directly, like the bash it replaces; adding a `tsconfig` + compile stage buys little here.
Use Node with JSDoc types (or `.ts` run via `node --experimental-strip-types`, not a bundler) and
`zod` for the one boundary that matters — parsing `WORKFLOW.md`. The CLAUDE.md "TS strict + zod"
guidance is written for application code; for this tool, keep `zod` at the config boundary and skip
the toolchain. Rationale for Node over staying in bash: an embedded HTTP server for the dashboard,
real async for concurrent attempts, and structured stream parsing. The per-stage Python
stream-parser and inline GraphQL collapse into typed adapters either way.

### 1A. `WORKFLOW.md` — the externalized contract (lives in the *target* repo)

The single most important Symphony idea: the rules describing how agents handle work are
**versioned with the code** and read **from the checked-out branch**, so each repo — and each
branch — can define its own states, branches, and commands without rebuilding the framework.

Autoframe ships a default `WORKFLOW.md`; the worked-on repo overrides it if present
(`$WORKSPACE/WORKFLOW.md` wins over the bundled default).

```markdown
---
tracker:
  type: linear
  team: ${LINEAR_TEAM_KEY}
  # optional: project_slug, required_labels: [agent]

defaults:
  agent: ${AGENT:-claude}          # claude | pi | codex
  timeout_silent_ms: 1800000       # 30m alive-but-silent → revert (today's STALE_THRESHOLD)
  timeout_tracker_ms: 3600000      # 60m no tracker update → cross-container revert
  workspace_root: /workspace/worktrees

dispatch:
  order: [priority, age]           # Tier 2: priority asc, then oldest-first
  concurrency: 2                   # global cap when running --stage all

retry:                             # Tier 3C
  max_attempts: 3
  base_ms: 10000
  factor: 2
  max_backoff_ms: 600000
  on_exhausted: Needs Human        # state to park a ticket that keeps failing

hooks:                             # Tier 3D (paths relative to workspace)
  after_create:  .autoframe/hooks/clone.sh
  before_run:    .autoframe/hooks/prepare.sh
  after_run:     .autoframe/hooks/collect.sh
  before_remove: .autoframe/hooks/teardown.sh

stages:
  - name: research
    poll:   [Todo]
    claim:  Research
    done:   Research Pending Approval
    revert: Todo
    command: /ticket-research
    tier: normal

  - name: plan
    poll:   [Research Approved]
    claim:  Planning
    done:   Plan Pending Approval
    revert: Research Approved
    command: /ticket-plan
    tier: advanced

  - name: process
    poll:   [Plan Approved, Changes Required]
    claim:  In Progress
    done:   Review Pending
    revert: Plan Approved
    command: /ticket-process
    tier: normal

  - name: review
    poll:   [Review Pending]
    claim:  In Review
    pass:   Human Review            # branch on agent verdict
    fail:   Changes Required
    revert: Review Pending
    command: /ticket-review
    tier: advanced

  - name: approve
    poll:   [Merging]
    claim:  Merging
    done:   Done
    revert: Human Review
    command: /ticket-approve
    tier: normal
---

# Agent operating rules

(Optional Markdown body = prompt preamble injected before each slash command.
Encodes repo-specific conventions: branch prefixes, test/lint commands, "what we never do".
This is where Symphony puts the agent prompt; autoframe keeps slash commands but lets the
repo prepend rules here.)
```

`workflow-loader.ts` parses frontmatter, expands `${ENV}`, zod-validates (every `poll`/`claim`/
`done`/`revert`/`pass`/`fail` must be a non-empty string; stage names unique; referenced states
need not pre-exist but are logged). **Invalid workflow → keep last validated config and log**
(Symphony's graceful-degradation rule), never crash the loop.

This single table replaces the hardcoded knobs in all 10 scripts.

**Who writes which tracker transition — engine vs. agent.** This split must be explicit or
implementers will create double-writes. Today the **slash command** performs the forward
transitions inside the agent run (`/ticket-process` sets `In Progress` → `Review Pending`); the
bash wrapper only does the claim and the revert-on-failure. Keep that division — it's also the
faithful-Symphony model ("tracker writes are performed by the coding agent"):

| Transition | Owner | Why |
|---|---|---|
| `poll` → `claim` (claim for dispatch) | **engine** | needs the atomic claim (Redis/tracker CAS) before launch |
| `claim` → `done` / `pass` / `fail` (forward progress) | **agent (slash command)** | the agent knows the outcome; it already writes these today |
| any → `revert` (stale/failed reclaim) | **engine** | reconciliation owns recovery when the agent is dead or silent |

So `done`/`pass`/`fail` in the stages table are **declared** for the engine's reconciliation and
snapshot logic (it must recognize a terminal state to release the claim), **not** a second writer
that races the agent. The engine drives `poll`/`claim`/`revert`; the agent drives the forward
write. If a future version moves forward writes into the engine, every slash command must be
edited to stop writing in the same change — never add engine forward-writes alongside the existing
command writes.

### 1B. One scheduler engine (replaces the 10 poll loops)

`core/scheduler.ts` is a pure state machine driven by a single-authority tick (Symphony's model),
replacing today's five independent bash loops:

```
tick():
  1. reconcile running attempts        # stall detection + tracker-state refresh
  2. recover stale claims              # generalizes revert_stale_claims + revert_stale_linear_claims
  3. for each enabled stage:
       candidates = tracker.fetchCandidates(stage.poll)
  4. sort candidates by dispatch.order # Tier 2
  5. dispatch up to (concurrency - running) that are not claimed and not retry-backing-off
  6. schedule next tick (poll_interval), or immediate if work remains
```

Claim model (`core/claim.ts`), lifted from Symphony, formalizes today's implicit claim state:
`Unclaimed → Claimed{Running | RetryQueued} → Released`.

**Where cross-container exclusion actually comes from today — and why fs locks don't provide it.**
`/tmp` is **not** a shared volume (verified: no `tmpfs`, no `/tmp` mount, no `volumes_from` in
`docker-compose.yml`). Under `--scale process=3` each container gets its own `/tmp`, so the
`mkdir /tmp/<prefix>-lock-*` lock is **intra-container only** — and within one container the poll
loop already processes tickets serially, so that lock guards almost nothing. The real thing
stopping two *containers* from grabbing the same ticket is the **tracker state machine**: a claim
flips the ticket out of the poll set (e.g. `Plan Approved` → `In Progress`), and
`revert_stale_linear_claims` reclaims it via `updatedAt` age. That exclusion is **not atomic**:
poll→launch has a window where two containers both see `Plan Approved` in the same ~60s tick and
both launch. Today this is tolerated (rare; the second attempt wastes work, and stale-revert
cleans up), but the design must not claim a safety property that isn't there.

So the claim authority depends on deployment mode:
- **`--stage all` (single supervised process):** in-memory claims are sufficient and *sound* —
  one process owns dispatch, no cross-process race. This is the recommended small-fleet shape and
  the simplest correct answer.
- **Multi-container (`--scale`, or one container per stage that can be scaled):** the claim must
  be **atomic in shared state**, not the filesystem. Two options: (a) a tracker-atomic
  compare-and-set on the state transition (claim only if the ticket is still in the poll state),
  or (b) **Redis** — which CLAUDE.md already mandates for shared state (positions, locks) and is
  the natural home for a `SET claim:<ticket> <owner> NX PX <ttl>` claim with a TTL that the
  heartbeat renews. `claim-store.ts` is that port; `fs-store.ts` keeps only the intra-container
  heartbeat/attempt records.

This is a correctness *improvement* over today, not just a refactor: it closes the double-launch
window the bash system leaves open.

Run-attempt lifecycle (`core/attempt.ts`), also from Symphony, replaces the ad-hoc heartbeat/
watchdog spaghetti with explicit states:
`PreparingWorkspace → BuildingPrompt → Launching → Streaming → Finishing →
{Succeeded | Failed | TimedOut | Stalled | CanceledByReconciliation}`.
The existing watchdog thresholds map onto `TimedOut` (silent > `timeout_silent_ms`) and `Stalled`
(no tracker update > `timeout_tracker_ms`); `CanceledByReconciliation` is today's status-watcher
(ticket moved out from under us).

**Deployment**: the engine takes `--stage <name>` or `--stage all`.
- `--stage process` → same container-per-stage model as today (failure isolation, independent
  scaling via `--scale`), but one shared codebase.
- `--stage all` → one supervised process owns every stage with global concurrency + a unified
  dashboard (Symphony's single-supervisor shape). Recommended for small fleets / local runs.

### 1C. Agent adapter — collapse the claude/pi/codex duplication

The `-pi` scripts exist only because the agent binary and stream format differ. One port erases
all five duplicate files:

```ts
interface AgentPort {
  run(opts: {
    command: string;                 // "/ticket-process TICKET-15"
    cwd: string;
    attempt: number;                 // Tier 3C — surfaced to the prompt
    onEvent(e: AgentEvent): void;    // normalized stream
  }): Promise<AgentResult>;          // { exitCode, tokens, verdict? }
}

type AgentEvent =
  | { kind: 'phase';   title: string }                       // drives the banner
  | { kind: 'tool';    name: string; hint?: string }
  | { kind: 'text';    text: string }
  | { kind: 'error';   message: string }
  | { kind: 'tokens';  input: number; output: number; total: number };  // Tier 3B
```

- `claude-agent.ts` spawns `claude --dangerously-skip-permissions --no-session-persistence -p
  <command> --output-format stream-json --include-partial-messages` and maps stream-json →
  `AgentEvent` (the existing `/tmp/ticket-processor-*.py` logic moves here, once, typed).
- `pi-agent.ts` spawns the pi binary and maps its stream. The `-pi` scripts disappear.
- `codex-agent.ts` (future) speaks Codex App Server over stdio — this is the **Symphony interop
  point**: same engine, Codex as a drop-in agent.

The engine is agent-agnostic; the adapter is chosen by `defaults.agent` / `--agent` / `$AGENT`.

### Tier 1 result

- 10 scripts (~7,500 LOC) → 1 engine + 1 config file + 3 thin adapters.
- Adding a stage = a YAML block. Adding an agent = one adapter class.
- Per-repo customization without touching the framework or rebuilding the image.

---

## Tier 2 — Priority-ordered dispatch (cheapest win)

Today `parse_ticket_ids` sorts by ticket number (`sort -t- -k2 -n`,
`autonomous-agent-process.sh:328`) — arbitrary w.r.t. business priority.

Change: select `priority`/`createdAt` in the candidate query and sort `priority asc` (Linear: 1=
urgent … 4=low, 0=none → treat as lowest), then `createdAt asc`.

```graphql
issues(filter:{ team:{key:{eq:$TEAM}}, state:{name:{in:$POLL}} }) {
  nodes { identifier priority createdAt }
}
```

```ts
// core/dispatch.ts
const order = (a, b) =>
  prioRank(a.priority) - prioRank(b.priority) ||      // urgent first
  a.createdAt.localeCompare(b.createdAt);             // oldest first
const prioRank = p => (p === 0 ? 5 : p);              // "no priority" sinks to the bottom
```

This is a few lines and can land **today in bash** (Phase 0) ahead of the engine: extend the
query, swap the `sort` for a priority-aware Python sort in `parse_ticket_ids`.

---

## Tier 3 — Secondary improvements

### 3A. Central status view + snapshot API

Today: tail up to five `docker compose logs`; in-flight state is implicit in `/tmp` files.

- **`autoframe status` CLI (interim, no server):** read the heartbeat/attempt records and print a
  table — running tickets, stage, phase, elapsed, attempt, last-event age. Works against the
  *current* bash system immediately (it reads `/tmp/*-heartbeat-*`), but note these are
  **per-container** files, so a multi-container fleet needs the snapshot API below (or a shared
  claim store) to get a complete picture — the interim CLI only sees its own container.
- **`GET /api/v1/snapshot` (with the engine):** `{ running:[{ticket,stage,phase,elapsed,tokens}],
  retry_queue:[{ticket,stage,next_at,attempt}], recent:[...], totals:{tokens_today} }`.
- **`GET /` status page:** minimal HTML polling the snapshot (Symphony uses Phoenix LiveView;
  a static page + fetch is enough). Gated behind `--port`, off by default.

### 3B. Token / cost accounting

The `tokens` `AgentEvent` (1C) is captured from each agent's stream (claude stream-json `result`
usage; pi/codex equivalents). Per attempt: accumulate input/output/total, persist to the attempt
record, surface in the per-phase summary, the snapshot, and a rolling daily total. Optional
`budget_tokens` per stage in WORKFLOW.md → engine cancels an attempt that blows the cap
(`CanceledByReconciliation`) and parks the ticket. Important for a fleet that scales to many
parallel agents and currently reports **zero** cost.

### 3C. Retry with backoff + attempt metadata

Today a failed ticket is simply re-polled every 60s, forever, with no memory.

- Track `attempt` per (ticket, stage) durably in `StorePort`.
- On failure, set claim to `RetryQueued` with
  `next_at = now + min(base_ms * factor^(attempt-1), max_backoff_ms)`; the scheduler skips it
  until then (Symphony's exponential backoff).
- Pass `attempt` into the command (`/ticket-process TICKET-15 --attempt 2`) so the slash command
  can read prior-failure context and adapt instead of repeating the same path.
- At `max_attempts`, move the ticket to `retry.on_exhausted` (e.g. `Needs Human`) and post a
  comment — replacing today's silent infinite retry.

### 3D. Declarative lifecycle hooks

Generalize the clone/bootstrap currently baked into `entrypoint.sh` into per-repo hooks declared
in WORKFLOW.md (Symphony's `after_create` / `before_run` / `after_run` / `before_remove`):

| Hook | When | On failure |
|---|---|---|
| `after_create` | workspace/worktree first created | abort creation |
| `before_run` | before each attempt | abort attempt |
| `after_run` | after each attempt (artifact capture) | log + ignore |
| `before_remove` | before worktree teardown | log + ignore |

Each is a shell script with a timeout (default 60s). This moves per-repo setup (deps, codegen,
fixtures) from image-baked logic into **data in the target repo** — the same externalization
principle as WORKFLOW.md, applied to environment setup.

---

## Migration plan (strangler-fig — each phase ships independently)

**Phase 0 — De-dup in place (bash, ~days, zero behavior change).**
Extract the shared boilerplate into `scripts/lib/agent-core.sh`; reduce each stage to a thin
config (`scripts/stages/<stage>.env`: poll/claim/done/revert/command/prefix). 10 scripts →
1 lib + 10 small configs. Land **Tier 2 priority sort** here. Fully reversible, no new runtime.

**Phase 1 — Externalize the contract.**
Add `workflow-loader` + a default `WORKFLOW.md`; have `agent-core.sh` source its config from the
loader instead of hardcoded states. The target repo can now override states/commands. Branch
conventions and test commands move into the WORKFLOW.md body / hooks.

**Phase 2 — Engine behind a flag.**
Build `core/` + `adapters/` in Node/TS (TDD, fakes for ports). Run `autoframe run --stage process`
in parallel with the bash process agent on a test team to validate parity. Add `claude-agent`,
then `pi-agent` — **the `-pi` scripts and their 5 compose services delete here.**

**Phase 3 — Cut over + light up Tier 3.**
Move all stages to the engine. Add snapshot API + status page (3A), token accounting (3B),
retry/backoff (3C), hooks (3D). Remove the bash scripts. Compose now runs one image with
`--stage <name>` (or one `--stage all` service).

---

## Trade-offs / risks

- **Bash → Node = more machinery.** Mitigate: zero-dep core, small surface, TDD per CLAUDE.md;
  Phase 0/1 deliver most of the de-dup value with *no* runtime change, so the rewrite is optional
  upside, not a prerequisite.
- **`--stage all` reduces failure isolation** (one crash touches every stage). Mitigate: keep the
  per-stage process option; run under a supervisor (compose `restart: unless-stopped`, as today).
- **WORKFLOW.md from an untrusted repo could misdirect agents.** Mitigate: zod schema + safe
  defaults for omitted policy + workspace-path containment checks (Symphony's invariant: resolved
  workspace path MUST stay under `workspace_root`).
- **Decision point for whoever implements:** stop at Phase 1 (bash, de-duped, config-driven) or go
  through Phase 3 (Node engine, dashboard, token accounting). Phases 0–1 are low-risk and
  independently valuable; 2–3 are the larger investment that also unlocks Codex interop.

---

## Mapping back to the raised improvements

| Raised improvement | Designed as |
|---|---|
| Externalize per-repo workflow/config | 1A WORKFLOW.md + workflow-loader |
| Collapse Claude/Pi duplication | 1C AgentPort + adapters; one engine 1B |
| Write a spec / single orchestrator | 1B scheduler (claim model + attempt lifecycle) |
| Priority-ordered dispatch | Tier 2 (lands in Phase 0) |
| Central dashboard + snapshot API | 3A |
| Token / cost accounting | 3B (via AgentEvent.tokens) |
| Retry backoff + attempt metadata | 3C |
| Lifecycle hooks | 3D |
| Codex interop (Symphony's agent) | 1C codex-agent.ts |
