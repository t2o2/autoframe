---
description: Review a Linear ticket (input state: Review Pending) — run tests, validate in browser, move to Human Review or Changes Required
runInPlanMode: false
scope: project
---

Review a completed Linear ticket: run tests, validate in-browser, upload proof, post structured review, move to Human Review (PASS) or Changes Required (FAIL). All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Claim & Locate Branch

Fetch in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}"
bash ~/.agents/skills/linear/list-states.sh
```

Claim immediately:
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <in_review_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Picking up review for {{ARGUMENTS}}."
```

Find branch from comments (`.comments.nodes[].body`): match `**Branch:** \`feat/{{ARGUMENTS}}\`` or `fix/`. Fallback: `git branch -r | grep "{{ARGUMENTS}}"`.

No branch found → post comment, move to Changes Required, exit.

```bash
TICKET="{{ARGUMENTS}}"
BRANCH="feat/${TICKET}"     # or fix/ from comment
WORKTREE="../worktrees/${BRANCH}"
```

---

## Phase 1 — Locate Worktree

Reuse the implementation worktree from `/ticket-process`:
```bash
git fetch origin "${BRANCH}"
if wtp ls 2>/dev/null | grep -q "${BRANCH}"; then
  echo "Reusing existing worktree"
else
  wtp add -b "${BRANCH}" 2>/dev/null || git worktree add "${WORKTREE}" "${BRANCH}"
fi
```

All reads/writes use `$WORKTREE`.

---

## Phase 2 — Understand Implementation

From comments + thought store, extract: files changed, acceptance criteria, ticket type.

```bash
[ -f "thoughts/tickets/{{ARGUMENTS}}/plan.md" ] && echo "Plan found"
[ -f "thoughts/tickets/{{ARGUMENTS}}/research.md" ] && echo "Research found"
```

No implementation found (no commits beyond develop) → post comment, Changes Required, exit.

---

## Phase 2b — Validate Claims Against Git

```bash
cd "${WORKTREE}"
ACTUAL_FILES=$(git diff develop...HEAD --name-only | sort)
```

Compare actual vs claimed files:
- Claimed but not in diff → "claimed but not implemented"
- In diff but not claimed → "undeclared scope change"
- Mismatch > 30% → post comment, document in review

Empty diff → Changes Required, exit.

---

## Phase 3 — Code Review

Launch `Explore` agent (quick) scoped to changed files. Check: acceptance criteria match, error handling, edge cases, regressions. Record concerns with `file:line`.

---

## Phase 4 — Tests

**Tests are not complete until visual evidence is captured and attached to the Linear ticket. Text output alone is never sufficient.**

Run from worktree:
```bash
cd "${WORKTREE}" && cargo test -j 2 --all -- --test-threads=2 2>&1
cd "${WORKTREE}/keeper" && npm test 2>&1
cd "${WORKTREE}/frontend-issuance" && pnpm lint && pnpm build 2>&1 | tail -40
```

**Missing test coverage** → write tests (TDD: fails on develop, passes on branch), commit + push to branch.

Capture full output for the review comment.

**Evidence requirement (mandatory — same bar as Phase 5):**

- **UI/frontend changes**: start a screen recording before running any browser-driven test (`agent-browser record start "${PROOF_DIR}/test-run.webm"`), take at minimum one screenshot per acceptance criterion as it is exercised, stop recording after all tests complete. Recording and screenshots must be uploaded to Linear GCS (see Phase 5 upload steps) and asset URLs recorded before moving on.
- **API/backend changes**: save all `curl` responses to `${PROOF_DIR}/` during test execution — not just from a manual follow-up.
- **No exceptions**: a Phase 4 that produces only terminal text is incomplete. Missing evidence = FAIL.

---

## Phase 5 — Visual Proof (Mandatory — Never Skip)

```bash
PROOF_DIR="/tmp/screenshots/{{ARGUMENTS}}-review"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets

Use **agent-browser**: `open URL` → `snapshot -i` → interact via `@ref` → `screenshot path`.

**Start recording:** `agent-browser record start "${PROOF_DIR}/review-recording.webm"`

Walk each acceptance criterion. For each: action → snapshot → screenshot → check console.

**Upload screenshots to Linear GCS:** convert to JPEG (`sips -s format jpeg -Z 1200`), then:
1. `source ~/.agents/skills/linear/_lib.sh` → `linear_gql` FileUpload mutation → `uploadUrl` + `assetUrl`
2. `curl -X PUT` to GCS
3. Record `ASSET_URL_STEP_N`

Stop recording, save to `thoughts/tickets/{{ARGUMENTS}}/`.

Minimum: initial state, happy path, error state. Browser failure = FAIL (never skip UI proof).

### API / Backend Tickets

```bash
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' -d '[body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-[criterion]-happy.json"
```

Capture: happy path, error case, state-change confirmation. Embed as code blocks in review comment.

### Verify

All proof files must exist and asset URLs recorded before Phase 6.

---

## Phase 6 — Verdict & Documentation

**PASS** = all tests pass + no regressions + all criteria met + all proof uploaded.
**FAIL** = any test fails OR criterion unmet OR proof missing OR blocking bug.

Post **one** comprehensive review comment via `add-comment.sh` with these sections:

1. **Header**: PASS ✅ / FAIL ❌, reviewer, date, branch, status change
2. **Files changed**: path + what changed
3. **Acceptance criteria**: checklist with met/unmet
4. **Scope validation**: claimed vs actual files table
5. **Test results**: suite | command | outcome table + full failure output
6. **Visual proof**: inline screenshots `![alt]($ASSET_URL)` for UI, JSON code blocks for API
7. **Code review findings**: file:line concerns (or "No issues found")
8. **Reproduction steps** (FAIL only): numbered steps, expected vs actual
9. **Verdict**: 1–2 sentences why

Write review artifact to `thoughts/tickets/{{ARGUMENTS}}/review.md`.

---

## Phase 7 — Update Linear Status

**PASS:**
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <human_review_uuid>
```

**FAIL:**
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <changes_required_uuid>
```

---

## Phase 8 — Hand Off

- **FAIL**: inform user, leave worktree untouched for implementer
- **PASS**: `AskUserQuestion` — "Review PASSED. System still running at :8105/:8101/:8104. Full report on Linear. Move the ticket from **Human Review → Retrospective** to trigger the automated retrospective + merge."

Worktree is NOT removed — owned by `/ticket-approve`.

---

## Status Transitions

```
Review Pending  →  In Review        (Phase 0)
In Review       →  Human Review     (PASS)
In Review       →  Changes Required (FAIL)
```

## Critical Rules

1. Read existing comments first — don't redo completed work
2. Never PASS without running tests — if tests can't run, FAIL
3. Write missing tests before judging
4. Visual proof mandatory — no exceptions. Browser failure = FAIL
5. Screenshots as `![alt](assetUrl)` inline; API as code blocks
6. One comprehensive comment — not incremental updates
7. Never remove the worktree
8. NEVER move to Done — only valid PASS destination is Human Review
9. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
