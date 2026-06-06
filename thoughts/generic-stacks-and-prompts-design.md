# Autoframe — Generic Stacks & Custom Prompts: Design

> How to make autoframe drive *any* repo (any language/build/tracker) with *customizable*
> prompts, without touching the engine.
> Status: proposal. No code changed yet.

## Problem statement

The **engine** is already generic. `core/` (scheduler, dispatch, claim, ports) is stack-agnostic,
`workflow.toml` drives the state machine declaratively, and `core/ports.js` defines clean
`TrackerPort` / `AgentPort` seams. What is *not* generic is everything the agent actually executes:

1. **The prompts** (`.claude/commands/*.md`) hardcode one stack and one tracker.
2. **The tracker** — `TrackerPort` exists, but prompts + `workflow.toml` assume Linear in practice.

Concretely, the stack/tracker literals live here:

| Coupling | Location | Example |
|---|---|---|
| Test / build / lint commands | `ticket-process.md` Phase 5 | `cargo test -j 2 --all`, `keeper/ npm test`, `frontend-issuance/ pnpm lint && pnpm build` |
| Dev ports / proof URLs | `ticket-process.md` Phase 6 | `localhost:8104`, `frontend-issuance/` |
| Base branch | scattered across commands | `${GIT_BASE_BRANCH:-develop}` |
| Branch convention | `ticket-process.md` Phase 0 | Bug → `fix/`, else → `feat/` |
| Tracker API | every command file | direct `~/.agents/skills/linear/*.sh` calls |
| Tracker type | `workflow.toml` | `tracker.type = "linear"` (only adapter that exists) |

So a new user adopting autoframe for, say, a Go service tracked in GitHub Issues must hand-edit
every command markdown file. That is the gap.

## Design principle

Separate three concerns that are currently fused inside the prompt markdown:

```
THE LOOP        →  workflow.toml + core/        (already generic — leave alone)
THE STACK       →  project profile              (new — what "test/build/prove" means here)
THE TRACKER     →  TrackerPort + skill iface    (port exists; prompts must stop hardcoding it)
```

Prompts become **templates over `{profile, stage, tracker}`**. The markdown describes *what* to do
(claim → implement → test → prove → push); the profile says *how* for this repo; the tracker
interface says *where* the work items live. Customizing autoframe for a repo then means editing
config + (optionally) command markdown — never the engine.

---

## Part 1 — Project profile (biggest win, lowest effort)

### What

Add a `[project]` section to `workflow.toml` (resolved the same way `.env.project` already is, so it
can be symlinked per repo). It holds everything stack-specific that is currently inlined in prompts:

```toml
[project]
language       = "rust"
base_branch    = "develop"
branch_feat    = "feat/"
branch_fix     = "fix/"
test_command   = "cargo test -j 2 --all -- --test-threads=2"
build_command  = "cargo build"
lint_command   = "cargo clippy"
dev_url        = "http://localhost:8104"
frontend_dir   = "frontend-issuance"
ui_globs       = ["frontend-issuance/**"]
```

### How it reaches the prompt

We already have the injection hook: `[preamble].text` in `workflow.toml` is currently empty and
unused. Two mechanisms, both viable:

- **Preamble injection (cheapest):** render the profile into the preamble block that prepends every
  agent invocation. Prompts read it as ambient context.
- **Template variables (cleaner):** expose profile keys as `{{TEST_COMMAND}}`, `{{DEV_URL}}`,
  `{{UI_GLOBS}}`, `{{BASE_BRANCH}}` and substitute at dispatch time (alongside the existing
  `{{ARGUMENTS}}`).

Then strip the literals out of the markdown. `ticket-process.md` Phase 5 goes from:

```
cd "${WORKTREE}" && cargo test -j 2 --all -- --test-threads=2 2>&1
cd "${WORKTREE}/keeper" && npm test 2>&1
cd "${WORKTREE}/frontend-issuance" && pnpm lint && pnpm build 2>&1 | tail -30
```

to:

```
Run: {{TEST_COMMAND}}
UI changes (under {{UI_GLOBS}}): screenshot acceptance criteria against {{DEV_URL}}
```

One command file, N stacks.

### Engine changes

- Extend `WorkflowSchema` in `adapters/outbound/workflow-loader.js` with an optional `project`
  object (all fields optional, sensible defaults — keep the "never throws / graceful degradation"
  rule).
- Mirror in `scripts/lib/workflow-loader.sh`.
- Add template substitution where `command` is currently rendered for dispatch.

### Why this is first

Pure refactor of existing markdown + one schema extension. No new adapters, no new processes. It
unlocks "different stacks" on its own.

---

## Part 2 — Tracker-agnostic prompts

### The problem

Prompts call `~/.agents/skills/linear/get-issue.sh`, `update-issue.sh`, `add-comment.sh`,
`list-states.sh` directly. This is the deepest coupling — even with a `github` `TrackerPort` adapter
on the engine side, the *agent* would still shell out to Linear.

### Option A — Stable skill interface (cheap, recommended first)

Define a tracker-neutral skill contract and ship one implementation per tracker:

```
tracker/get-issue.sh <id>
tracker/update-state.sh <id> <state>
tracker/add-comment.sh <id> <body>
tracker/list-states.sh
```

Implementations: `tracker-linear/`, `tracker-github/`, `tracker-jira/`. The profile (Part 1) selects
which is on `PATH`. Prompts call `tracker/*` and never name a vendor again.

### Option B — Route through TrackerPort (cleaner, more work)

Expose the existing `TrackerPort` to the agent as a thin CLI so the markdown stops making API calls
at all. Better long-term, but larger change; do after Option A proves the interface.

### Engine side

`workflow.toml` already namespaces `tracker.type` / `tracker.team`. Add `github` / `jira`
`TrackerPort` adapters next to `adapters/outbound/linear-tracker.js` (it already conforms to the
port and is tested — copy the shape). The scheduler/dispatch need no changes.

---

## Part 3 — State vocabulary as data

`workflow.toml` stages already parameterize every state name (`poll`, `claim`, `done`, `revert`,
`pass_state`, `fail_state`) — that part is generic. The remaining leak is that
`create-autonomous-agent.md` and `README.md` describe the Linear state vocabulary as if fixed.

Action: keep the state→stage mapping in `workflow.toml` as the single source of truth (it already
is), and ensure prompts reference states via config/preamble rather than naming them inline. No new
mechanism — just discipline + doc updates.

---

## Sequencing

1. **Profile + preamble/template injection** (Part 1) — refactor markdown, extend schema. Unlocks
   different stacks. No new adapters.
2. **Tracker skill interface** (Part 2, Option A) — unlocks different trackers. Add `github`
   `TrackerPort` adapter in parallel.
3. **Scaffold/init command** — extend `create-autonomous-agent.md` to generate `workflow.toml`
   (incl. `[project]`) + a per-stack command set from a few prompted answers, so onboarding a new
   repo is `init` → fill profile → run.

After (1)+(2), "custom prompts" falls out for free: prompts are templates over
`{profile, stage, tracker}`, and a user customizing for their repo edits the profile + command
markdown, leaving `core/` and the scheduler untouched.

## Risks / open questions

- **Template engine scope:** keep substitution dumb (`{{KEY}}` string replace) to avoid pulling in a
  templating dependency on the hot dispatch path. Profile values are trusted (repo-local config).
- **Profile vs `.env.project` overlap:** credentials stay in `.env.project`; the profile is
  non-secret build/stack metadata. Keep the split clean.
- **Multi-package repos** (the current repo has `keeper/` + `frontend-issuance/` + Rust root): the
  profile needs either a list of `(dir, test_cmd)` tuples or a single composite `test_command`.
  Start with a single composite string; promote to a list only if needed.
- **Backward compat:** all `[project]` fields optional with defaults that reproduce today's behavior,
  so existing setups keep working with no profile present.
