---
description: Autonomously process a Linear ticket end-to-end in an isolated git worktree (fetch → claim → implement → close)
argument-hint: "<ticket-id>"
---

Process a Linear ticket: fetch → claim → implement → test → proof → push. Each ticket gets its own worktree branch. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: $ARGUMENTS

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

Fetch in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "$ARGUMENTS"
bash ~/.agents/skills/linear/list-states.sh
```

Check for plan artifact: `thoughts/tickets/$ARGUMENTS/plan.md`

Parse: title, description, priority, labels, status, team ID.

**Dependency check:** If parent exists, fetch siblings. Prerequisite in Todo/Backlog → process it first.

Vague description → post comment + `ask_user_question`.

---

## Phase 2 — Claim the Ticket

```bash
bash ~/.agents/skills/linear/update-issue.sh "$ARGUMENTS" --state-id <in_progress_uuid>
bash ~/.agents/skills/linear/add-comment.sh "$ARGUMENTS" "Picked up on branch \`${BRANCH}\`."
```

Write initial handoff to `thoughts/tickets/$ARGUMENTS/handoff.md` with: ticket, branch, git_commit, last_completed_phase: 2, date, status: in_progress.

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

Fix failures (up to 2 attempts). Update handoff: `last_completed_phase: 5`.

---

## Phase 5b — Visual Proof (Mandatory)

**No ticket moves to Review Pending without proof uploaded to Linear.**

```bash
PROOF_DIR="/tmp/screenshots/$ARGUMENTS"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets

Use `agent_browser`: open → snapshot → interact → screenshot per criterion.

Upload each screenshot to Linear GCS:
1. `sips -Z 1200` to downscale
2. `source ~/.agents/skills/linear/_lib.sh` → `linear_gql` FileUpload mutation → get `uploadUrl` + `assetUrl`
3. `curl -X PUT` to upload
4. Record each `ASSET_URL_STEP_N` for the completion comment

Minimum: initial state, happy path, error state. Frontend fails → `ask_user_question`.

### API / Backend Tickets
```bash
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' -d '[body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-proof-[criterion]-happy.json"
```
Upload to Linear via `_lib.sh` + `linear_gql` FileUpload mutation.

### Verify

```bash
ls -la "${PROOF_DIR}/"
```
All proof files must exist before Phase 6.

---

## Phase 6 — Commit, Push & Hand Off

```bash
cd "${WORKTREE}" && git add -A && git commit -m "$ARGUMENTS: feat: [description]
- [changes]
Fixes $ARGUMENTS"
git push -u origin "${BRANCH}"
```

Update status:
```bash
bash ~/.agents/skills/linear/update-issue.sh "$ARGUMENTS" --state-id <review_pending_uuid>
```

Post completion comment with: **Branch name** (required), files changed, test summary, inline screenshots `![alt]($ASSET_URL)`, API JSON blocks, "Next step: `/ticket-review $ARGUMENTS`".

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
8. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools. For proof uploads: `source ~/.agents/skills/linear/_lib.sh` then use `linear_gql` for FileUpload + `curl -X PUT` to GCS.
