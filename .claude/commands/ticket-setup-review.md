---
description: Set up the environment for human review of a Linear ticket — checkout branch, start services, execute prerequisites, and present the final state for human judgement
runInPlanMode: false
scope: project
---

Prepare a running environment for human review: checkout branch, start needed services, execute all prerequisites, present the exact outcome for judgement. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Fetch Ticket & Find Branch

```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}"
```

Find branch from comments (`**Branch:** \`feat/{{ARGUMENTS}}\`` or `fix/`). Fallback: `git fetch --all --prune && git branch -r | grep "{{ARGUMENTS}}"`.

No branch → stop: "Run `/ticket-process {{ARGUMENTS}}` first."

```bash
TICKET="{{ARGUMENTS}}"
BRANCH="feat/${TICKET}"     # or fix/
WORKTREE="../worktrees/${BRANCH}"
```

Extract: ticket title, acceptance criteria, ticket type.

---

## Phase 1 — Locate Worktree

Reuse impl worktree:
```bash
git fetch origin "${BRANCH}"
wtp ls 2>/dev/null | grep -q "${BRANCH}" || wtp add -b "${BRANCH}" 2>/dev/null || git worktree add "${WORKTREE}" "${BRANCH}"
cd "${WORKTREE}" && git pull origin "${BRANCH}" --ff-only 2>/dev/null || true
```

---

## Phase 2 — Analyse Changes & Classify Review Type

```bash
cd "${WORKTREE}"
git diff develop...HEAD --name-only
```

Classify: frontend → UI review, keeper/starfish/gateway → API/backend, docs only → doc review, config → config review.

Launch quick `Explore` agent on changed files → what changed, which criteria each satisfies, prerequisites needed.

---

## Phase 3 — Start Infrastructure

Skip for docs/config-only. Otherwise:
```bash
docker ps --format '{{.Names}}' | grep -q postgres || just dev &
# Wait for postgres (up to 60s)
```

Run migrations if SQL files in diff.

---

## Phase 4 — Start Services

Start only what's needed. Health-check each:

- **Starfish** (:8101) — if starfish/ changed or needed for auth
- **Keeper** (:8104) — if keeper/ changed
- **Gateway** (:8100) — if gateway/ changed
- **Frontend** (:8105) — if frontend/ changed or UI review

Build from `$WORKTREE`, run in background, wait for health endpoint.

---

## Phase 5 — Execute Prerequisites & Present Final State

**Step 1:** From acceptance criteria + changes, determine: what outcome proves the ticket works? What actions create that state?

**Step 2:** Execute prerequisites using appropriate tools:
- **UI**: Chrome DevTools MCP — `resize_page(1280,800)` before navigate, login if needed, navigate to target
- **API**: curl with appropriate auth/body
- **Backend**: run tests or trigger behaviour from worktree
- **Docs**: `git diff develop...HEAD -- [files]`

Verify each step. Retry once on failure; report if still failing.

**Step 3:** Present final state — leave browser open (UI), display response (API), show output (backend).

---

## Phase 6 — Brief Handoff

```
╔═══════════════════════════════════════════════╗
║  READY FOR REVIEW — {{ARGUMENTS}}              ║
╚═══════════════════════════════════════════════╝

Ticket:   [title]
Branch:   [branch]
What changed: [1–2 sentences]
Presenting: [what the human sees now]

Prerequisites completed:
  [x] [action]

What to verify:
  - [criterion]

After review:
  Approve → /ticket-approve {{ARGUMENTS}}
  Reject  → Changes Required in Linear
```

---

## Critical Rules

1. Reuse impl worktree — never create a new one
2. Actually start services — run commands, wait for health checks
3. Start from worktree — branch code, not develop
4. Execute all prerequisites — automate every mechanical action
5. Stop at judgement point — present outcome, don't judge
6. Match medium to ticket — browser for UI, curl for API, tests for logic
7. Never post to Linear — terminal-only handoff
8. Keep services running after command finishes
9. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
