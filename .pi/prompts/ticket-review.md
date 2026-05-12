---
description: Review a Linear ticket (input state: Review Pending) — run tests, validate in browser, move to Human Review or Changes Required
argument-hint: "<ticket-id>"
---

Review a completed ticket: tests, browser validation, proof upload, structured review comment. Move to Human Review (PASS) or Changes Required (FAIL).

## Request

Ticket ID: $ARGUMENTS

---

## Phase 0 — Claim & Locate Branch

Fetch via `linear_gql` (bash+curl): issue details, workflow states, comments — in parallel.

Claim immediately:
```
linear_gql issueUpdate → { id, statusId: <in_review_id> }
```
Post: "Picking up review for $ARGUMENTS."

Find branch from comments: `**Branch:** \`feat/$ARGUMENTS\`` or `fix/`. Fallback: `git branch -r | grep "$ARGUMENTS"`.

No branch → post comment, Changes Required, exit.

```bash
TICKET="$ARGUMENTS"
BRANCH="feat/${TICKET}"     # or fix/ from comment
WORKTREE="../worktrees/${BRANCH}"
```

---

## Phase 1 — Locate Worktree

Reuse impl worktree:
```bash
git fetch origin "${BRANCH}"
wtp ls 2>/dev/null | grep -q "${BRANCH}" || wtp add -b "${BRANCH}" 2>/dev/null || git worktree add "${WORKTREE}" "${BRANCH}"
```
All reads/writes use `$WORKTREE`.

---

## Phase 2 — Understand Implementation

From comments + thought store: files changed, acceptance criteria, ticket type.
```bash
[ -f "thoughts/tickets/$ARGUMENTS/plan.md" ] && echo "Plan found"
[ -f "thoughts/tickets/$ARGUMENTS/research.md" ] && echo "Research found"
```
No implementation (no commits beyond develop) → Changes Required, exit.

---

## Phase 2b — Validate Claims Against Git

```bash
cd "${WORKTREE}"
ACTUAL_FILES=$(git diff develop...HEAD --name-only | sort)
```
Compare actual vs claimed. Flag discrepancies (>30% mismatch → post comment). Empty diff → Changes Required, exit.

---

## Phase 3 — Code Review

Launch `Explore` agent (quick) on changed files. Check: criteria match, error handling, edge cases, regressions. Record concerns with `file:line`.

---

## Phase 4 — Tests

```bash
cd "${WORKTREE}" && cargo test -j 2 --all -- --test-threads=2 2>&1
cd "${WORKTREE}/keeper" && npm test 2>&1
cd "${WORKTREE}/frontend-issuance" && pnpm lint && pnpm build 2>&1 | tail -40
```

Missing coverage → write tests (TDD: fails on develop, passes on branch), commit + push.

Capture full output for review comment.

---

## Phase 5 — Visual Proof (Mandatory — Never Skip)

```bash
PROOF_DIR="/tmp/screenshots/$ARGUMENTS-review"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets
Use **agent-browser**: `record start` → `open :8105` → `snapshot -i` → walk criteria → `screenshot` per step → convert JPEG (`sips -s format jpeg -Z 1200`) → upload via `linear_gql` `fileUpload` + `attachmentCreate` → record `assetUrl`.

`record stop` → save to `thoughts/tickets/$ARGUMENTS/`.

Minimum: initial state, happy path, error state. Browser failure = FAIL.

### API / Backend Tickets
```bash
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' -d '[body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-[criterion]-happy.json"
```
Upload to Linear. Verify attachment count via `get_issue`.

---

## Phase 6 — Verdict & Documentation

**PASS** = all tests pass + no regressions + all criteria met + all proof uploaded to Linear.
**FAIL** = any test fails OR criterion unmet OR proof missing OR blocking bug.

Post **one** review comment with: header (PASS/FAIL), files changed, acceptance criteria checklist, scope validation table, test results + full failure output, visual proof (`![alt](url)` for UI, JSON blocks for API), code review findings (file:line), reproduction steps (FAIL only), verdict.

Evidence standard: a fresh agent reading only ticket + comments must reproduce any failure in under 2 minutes.

Write artifact to `thoughts/tickets/$ARGUMENTS/review.md`.

---

## Phase 7 — Update Linear

- PASS → Human Review
- FAIL → Changes Required

---

## Phase 8 — Hand Off

- FAIL: inform user, leave worktree for implementer
- PASS: "Review PASSED. System running at :8105/:8101/:8104."

Worktree NOT removed — owned by `/ticket-approve`.

---

## Status Transitions

```
Review Pending  →  In Review        (Phase 0)
In Review       →  Human Review     (PASS)
In Review       →  Changes Required (FAIL)
```

## Critical Rules

1. Read existing comments first — don't redo work
2. Never PASS without running tests — can't run = FAIL
3. Write missing tests before judging
4. Visual proof mandatory — no exceptions. Verify via `get_issue` attachments count
5. Screenshots as `![alt](url)` inline; API as code blocks
6. One comprehensive comment — not incremental
7. Never remove worktree
8. NEVER move to Done — only valid PASS destination is Human Review
