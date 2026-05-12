---
description: Autonomously process a Linear ticket end-to-end in an isolated git worktree (fetch → claim → implement → close)
argument-hint: "<ticket-id>"
---

Process a Linear ticket: fetch → claim → implement → test → proof → push. Each ticket gets its own worktree branch.

## Request

Ticket ID: $ARGUMENTS

---

## Linear API

Use `LINEAR_API_KEY` env var for all ticket operations:

```bash
linear_gql() {
    local query="$1"
    curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\": $(echo "$query" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
        https://api.linear.app/graphql
}
```

Key operations: `issue(id:)` for details, `workflowStates(filter:{team:...})` for statuses, `issueUpdate` for status/assignee, `commentCreate` for comments, `fileUpload` + `attachmentCreate` for proof uploads.

---

## Browser Automation

Use `agent_browser` for all browser interactions:
```
agent_browser open http://localhost:8105
agent_browser snapshot -i
agent_browser screenshot /tmp/screenshots/step-1.jpg --format jpeg --quality 70
agent_browser click "@e3"
```
Workflow: `open URL` → `snapshot -i` → interact via `@ref` → `screenshot path`.

---

## Phase 0 — Worktree Setup

Determine branch type (Bug → `fix/`, else → `feat/`):
```bash
TICKET="$ARGUMENTS"
BRANCH="${BRANCH_TYPE}/${TICKET}"
WORKTREE="../worktrees/${BRANCH}"
git fetch origin "${GIT_BASE_BRANCH:-develop}"
wtp ls 2>/dev/null | grep -q "${BRANCH}" || wtp add -b "${BRANCH}" "origin/${GIT_BASE_BRANCH:-develop}"
```

> All subsequent operations **must use `$WORKTREE`**.

---

## Phase 0.5 — Resumption Check

```bash
HANDOFF="thoughts/tickets/$ARGUMENTS/handoff.md"
```
- Handoff exists + commits match → skip to `last_completed_phase + 1`
- Commits differ → start from Phase 3
- No handoff → proceed to Phase 1

---

## Phase 1 — Fetch & Analyze

Fetch via Linear GraphQL: issue details, workflow states, comments.

Check for plan artifact: `thoughts/tickets/$ARGUMENTS/plan.md`

Parse: title, description, priority, labels, status, team ID, issue UUID, type.

**Dependency check:** If parent exists, fetch siblings. Prerequisite in Todo/Backlog → process it first.

Vague description → post comment + `ask_user_question`.

---

## Phase 2 — Claim the Ticket

1. Set state to In Progress, assign to self
2. Post comment: "Picked up on branch `${BRANCH}`."
3. Write handoff artifact to `thoughts/tickets/$ARGUMENTS/handoff.md`

---

## Phase 3 — Explore & Plan

All reads from `$WORKTREE`.

- **Bug**: spawn `bug-investigator` — root cause, affected files, repro
- **Feature**: spawn `Explore` + `Plan` subagents
- Post key decisions as comments

---

## Phase 4 — Implement

Spawn `senior-implementer` with: ticket description, plan, worktree path. TDD. All changes in `$WORKTREE`.

Blockers → post comment + `ask_user_question`.

Update handoff: `last_completed_phase: 4`.

---

## Phase 5a — Automated Tests

```bash
cd "${WORKTREE}" && cargo test -j 2 --all -- --test-threads=2 2>&1
cd "${WORKTREE}/keeper" && npm test 2>&1
cd "${WORKTREE}/frontend-issuance" && pnpm lint && pnpm build 2>&1 | tail -30
```

Fix failures (up to 2 attempts). Update handoff.

---

## Phase 5b — Visual Proof (Mandatory)

**No ticket moves to Review Pending without proof.**

```bash
PROOF_DIR="/tmp/screenshots/$ARGUMENTS"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets
Use `agent_browser`: open → snapshot → interact → screenshot per criterion. Upload each to Linear via `fileUpload` mutation. Record `assetUrl` for completion comment.

Minimum: initial state, happy path, error state. Frontend fails → `ask_user_question`.

### API / Backend Tickets
```bash
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' -d '[body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-proof-[criterion]-happy.json"
```
Upload to Linear. Verify attachment count matches.

---

## Phase 6 — Commit, Push & Hand Off

```bash
cd "${WORKTREE}" && git add -A && git commit -m "$ARGUMENTS: feat: [description]
- [changes]
Fixes $ARGUMENTS"
git push -u origin "${BRANCH}"
```

Update status to Review Pending. Post completion comment with: **branch name** (required), files changed, test summary, inline screenshots `![alt](assetUrl)`, "Next step: `/ticket-review $ARGUMENTS`".

Worktree stays — do not remove.

---

## Status Transitions

```
Backlog / Todo  →  In Progress      (Phase 2)
In Progress     →  Review Pending   (Phase 6)
In Progress     →  Done             (Phase 6, self-contained)
```

## Critical Rules

1. Phase 0 first — `wtp add` before any file operation
2. All paths use `$WORKTREE` — never touch main repo
3. Never work on `develop` directly
4. Push before handing off
5. Record branch name in completion comment
6. Do not remove worktree — persists for review
7. Visual proof mandatory — Phase 5b cannot be skipped
