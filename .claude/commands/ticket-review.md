---
description: Review a Linear ticket (input state: Review Pending) — run tests, validate in browser, move to Human Review or Changes Required
runInPlanMode: false
scope: project
---

Review a completed Linear ticket. Run tests, validate the feature in-browser, upload proof to Linear, and move the ticket to the correct status.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Locate the Implementation Branch

Read the ticket comments to find the implementation branch posted by `/ticket-process`:

1. `mcp__linear-server__get_issue` and `mcp__linear-server__list_comments` — in parallel

2. Scan comments for a line matching: `**Branch:** \`feat/{{ARGUMENTS}}\`` or `\`fix/{{ARGUMENTS}}\``

3. If no branch is found in comments, fall back to checking git:

   ```bash
   git branch -r | grep "{{ARGUMENTS}}"
   ```

4. If still no branch exists — post a comment and stop:
   > "Review started for {{ARGUMENTS}}. No implementation branch found in comments or on origin. Cannot review. Moving to Changes Required — please run `/ticket-process {{ARGUMENTS}}` first."

   Move to Changes Required and exit.

Set:

```bash
TICKET="{{ARGUMENTS}}"
BRANCH="feat/${TICKET}"     # or fix/${TICKET} — from the comment
WORKTREE="../worktrees/${BRANCH}"   # reuse the implementation worktree directly
```

## Phase 1 — Locate Implementation Worktree

Reuse the existing implementation worktree left by `/ticket-process` — no new worktree needed.

```bash
# Fetch latest from origin first
git fetch origin "${BRANCH}"

# Check if the implementation worktree already exists
if wtp ls 2>/dev/null | grep -q "${BRANCH}"; then
  echo "Reusing existing implementation worktree for ${BRANCH}"
else
  # Worktree missing (e.g. review running without a prior ticket-process run)
  wtp add -b "${BRANCH}" 2>/dev/null || git worktree add "${WORKTREE}" "${BRANCH}"
  echo "Created worktree at ${WORKTREE}"
fi

# Confirm worktree path
command wtp cd "${BRANCH}" 2>/dev/null || echo "${WORKTREE}"
```

> All test runs and file reads use `$WORKTREE` as the base path. Any new tests written are committed to the implementation branch (`$BRANCH`) from inside this worktree.

---

## Phase 2 — Understand What Was Implemented

From the ticket comments (already fetched in Phase 0), extract:

- **Files changed** — listed in the completion comment from `/ticket-process`
- **Acceptance criteria** — from the original ticket description (Definition of Done, validation steps)
- **Ticket type** — Bug fix / Feature / Improvement (determines review strategy)

**Also check the thought store for richer context:**

```bash
PLAN_ARTIFACT="thoughts/tickets/{{ARGUMENTS}}/plan.md"
RESEARCH_ARTIFACT="thoughts/tickets/{{ARGUMENTS}}/research.md"
[ -f "$PLAN_ARTIFACT" ] && echo "Plan artifact found — reading phase checklist and key files" || echo "No plan artifact"
[ -f "$RESEARCH_ARTIFACT" ] && echo "Research artifact found — reading patterns and complexity" || echo "No research artifact"
```

If the ticket has no implementation comments and no commits beyond `develop`:

- Post comment: *"No implementation found on branch `${BRANCH}`. Tagging Changes Required — nothing to review."*
- Move to Changes Required and exit.

---

## Phase 2b — Validate Implementation Against Claims (Git Ground Truth)

**This phase runs before code review or tests. It establishes what actually changed vs. what was claimed.**

```bash
cd "${WORKTREE}"

# Actual changes on the branch
ACTUAL_FILES=$(git diff develop...HEAD --name-only | sort)

# Claimed changes from the process agent's completion comment
# (extract file paths from the "Files changed" section — one path per line)
CLAIMED_FILES=$(echo "[files extracted from completion comment]" | sort)

echo "=== Actual files changed ==="
echo "$ACTUAL_FILES"

echo "=== Claimed files changed ==="
echo "$CLAIMED_FILES"
```

Compare the two sets:

1. **Files claimed but not present in git diff** → flag as "claimed but not implemented"
2. **Files in git diff but not mentioned in completion comment** → flag as "undeclared scope change"
3. **If total mismatch > 30% of claimed files**: post a comment noting the discrepancy and document it prominently in the review report — this does not block the review but must be visible

Record discrepancies for inclusion in Phase 6 review comment under a "Scope Validation" section.

If `ACTUAL_FILES` is empty (no commits beyond develop):

- Post comment: *"No commits found on `${BRANCH}` beyond `develop`. Tagging Changes Required."*
- Move to Changes Required and exit.

---

## Phase 3 — Code Review

Launch an `Explore` agent (quick thoroughness) scoped to the changed files. Ask it to:

- Confirm the implementation matches the acceptance criteria in the ticket
- Flag missing error handling, edge cases, or obvious regressions
- Note which test suites apply (Rust / TypeScript / Frontend)

Record: file paths, functions changed, any concerns with `file:line` references.

---

## Phase 4 — Unit & Integration Tests

Run all applicable test suites from the review worktree. Run in parallel where independent:

**Rust** (`core/`, `gateway/`, `starfish/`, `tokenization/`):

```bash
cd "${WORKTREE}" && cargo test --all 2>&1
```

**Keeper / TypeScript**:

```bash
cd "${WORKTREE}/keeper" && npm test 2>&1
```

**Frontend**:

```bash
cd "${WORKTREE}/frontend-issuance" && pnpm lint && pnpm build 2>&1 | tail -40
```

**If the changed behavior has no test coverage** — write tests before judging:

- Rust: add `#[test]` or `#[tokio::test]` in the same module inside `$WORKTREE`
- TypeScript: add a test in `$WORKTREE/keeper/src/__tests__/`
- Follow TDD: confirm the new test fails first on `develop`, passes on this branch
- Commit new tests to the branch:

  ```bash
  cd "${WORKTREE}"
  git add -A
  git commit -m "$(cat <<'EOF'
  {{ARGUMENTS}}: test: add missing coverage for [behavior]

  Part of {{ARGUMENTS}}
  EOF
  )"
  git push origin "${BRANCH}"
  ```

Capture **full output** (stdout + stderr) — paste into the review comment regardless of outcome.

---

## Phase 5 — Visual Proof (Mandatory — Never Skip)

**Every ticket requires proof. There is no "backend-only" exception. NEVER mark a ticket PASS without evidence per acceptance criterion. All proof must be visible in the Linear app: screenshots as inline image previews, text responses as comment code blocks.**

Set the proof directory:

```bash
PROOF_DIR="/tmp/screenshots/{{ARGUMENTS}}-review"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets (any frontend changes)

Ensure services are running. If not:

```bash
just dev &
sleep 15
cd "${WORKTREE}/frontend-issuance" && pnpm dev &
sleep 10
```

Use Chrome DevTools MCP:

1. `mcp__chrome-devtools__new_page` — open fresh tab
2. `mcp__chrome-devtools__navigate_page` → `http://localhost:8105`
3. `mcp__chrome-devtools__list_console_messages` — capture baseline (no pre-existing errors)

Walk through **every acceptance criterion**. For each step:

- Perform the action (click, submit, navigate)
- `mcp__chrome-devtools__take_screenshot` → `${PROOF_DIR}/step-N-[criterion-slug].png`
- `mcp__chrome-devtools__list_console_messages` — confirm no new console errors
- **Immediately upload to Linear and record the returned URL:**

  ```bash
  SCREENSHOT_B64=$(base64 -i "${PROOF_DIR}/step-N-[criterion-slug].png")
  ```

  Call `mcp__linear-server__create_attachment`:

  - `issue`: `{{ARGUMENTS}}`
  - `base64Content`: base64 string above
  - `filename`: `step-N-[criterion-slug].png`
  - `contentType`: `image/png`
  - `title`: `[Review] [Step N] [Short description]`
  - `subtitle`: `{{ARGUMENTS}} — review proof`

  **Record the `url` returned by each `create_attachment` call.** These hosted URLs are embedded as inline markdown images in the Phase 6 review comment so reviewers see visual previews directly in Linear (not just sidebar download links).

**Minimum required screenshots (all must be uploaded):**

| State | Filename | Attachment title |
|---|---|---|
| Page on initial load | `step-1-initial-state.png` | `[Review] [Step 1] Initial state` |
| Happy path end state | `step-2-happy-path.png` | `[Review] [Step 2] Happy path` |
| Error / validation state | `step-3-error-state.png` | `[Review] [Step 3] Error state` |
| Each additional criterion | `step-N-[criterion].png` | `[Review] [Step N] [Criterion]` |

If `http://localhost:8105` is unreachable after attempting to start it — **this is a FAIL**:
> "Browser validation failed — frontend could not be started. Blocking review."

If the Chrome DevTools MCP tool fails or returns an error (e.g. "browser connection unavailable", "no page found") — **do not skip screenshots**. Instead:

1. Try `mcp__chrome-devtools__new_page` to open a fresh browser context and retry
2. If that also fails, **this is a FAIL** — report it explicitly and move to Changes Required:
   > "Browser validation failed — Chrome DevTools MCP unavailable. Cannot capture visual proof. Blocking review."

**Never give PASS for a UI ticket without at least one screenshot uploaded to Linear.** Browser MCP failure is a blocking condition, not a reason to bypass the proof requirement.

Do **not** proceed to Phase 6 without resolving it or marking FAIL.

### API / Backend Tickets (no frontend changes)

Run real curl commands against the live services. For each acceptance criterion:

```bash
# Happy path
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' \
  -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' \
  -d '[request body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-[criterion-slug]-happy.json"

# Error case
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' \
  -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' \
  -d '[invalid body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-[criterion-slug]-error.json"
```

If a criterion involves a state change, confirm with a follow-up GET and save to `api-[criterion-slug]-confirm.json`.

For Starfish-proxied endpoints requiring HMAC auth, use the demo credentials from `CLAUDE.md`.

**Upload each JSON file to Linear:**

```bash
API_B64=$(base64 -i "${PROOF_DIR}/api-[criterion-slug]-happy.json")
```

Call `mcp__linear-server__create_attachment`:

- `issue`: `{{ARGUMENTS}}`
- `base64Content`: base64 string above
- `filename`: `api-[criterion-slug]-happy.json`
- `contentType`: `application/json`
- `title`: `[Review] [API] [Criterion] — happy path`
- `subtitle`: `{{ARGUMENTS}} — review proof`

Repeat for error and confirm files.

**All JSON files must contain real server responses — not empty objects or mocked data.**

### Confirm All Attachments Uploaded

**Step 1 — verify files exist locally:**

```bash
ls -la "${PROOF_DIR}/"
```

**Step 2 — verify uploads reached Linear (mandatory):**

Call `mcp__linear-server__get_issue` with the issue UUID (from the issue fetched in Phase 0) and confirm `attachments` is non-empty. The count must equal the number of files you uploaded.

If `attachments` is empty or the count is lower than expected:

- Do **not** proceed to Phase 6
- Re-call `mcp__linear-server__create_attachment` for any missing files
- Re-check `get_issue` until counts match

This is the only reliable proof that files are visible to reviewers — local file existence alone is not sufficient.

---

## Phase 6 — Verdict & Documentation

Evaluate all findings from Phases 2–5:

**PASS** (all must be true):

- All tests pass (existing and any newly written)
- No regressions found in code review
- All acceptance criteria met (UI or API)
- All Definition of Done items from the ticket are satisfied
- Visual proof exists for every acceptance criterion and is confirmed uploaded to Linear
- Screenshots rendered as inline image previews in the review comment
- API JSON responses embedded as code blocks in the review comment

**FAIL** (any one is sufficient):

- Any test suite fails
- A critical acceptance criterion is not met
- Browser validation reveals a blocking bug
- Implementation is missing a key part of the ticket scope
- Visual proof is missing or not confirmed in Linear attachments

---

Build the review comment. Post via `mcp__linear-server__save_comment`. Every section is **mandatory**.

```markdown
## Review: [PASS ✅ / FAIL ❌] — {{ARGUMENTS}}

**Reviewer:** AI Review Agent
**Date:** [today's date]
**Branch reviewed:** `[branch name]`
**Status change:** [current status] → [new status]

---

### What Was Reviewed

**Files changed:**
- `[path/to/file]` — [what changed]
- `[path/to/file]` — [what changed]

**Commits on branch:**
[paste: git log develop..HEAD --oneline output]

**Acceptance criteria:**
- [x] [criterion] — met / ❌ not met: [reason]
- [x] [criterion] — met / ❌ not met: [reason]

---

### Scope Validation

**Claimed vs. actual files changed:**

| File | Claimed ✓/✗ | In Git Diff ✓/✗ | Note |
|---|---|---|---|
| `[file path]` | ✓ | ✓ | matched |
| `[file path]` | ✓ | ✗ | claimed but not changed |
| `[file path]` | ✗ | ✓ | changed but not claimed |

**Discrepancy level:** [none / minor / significant]

---

### Test Results

| Suite | Command | Outcome |
|---|---|---|
| Rust | `cargo test --all` | PASS ✅ / FAIL ❌ |
| Keeper | `npm test` | PASS ✅ / FAIL ❌ / skipped |
| Frontend | `pnpm lint && pnpm build` | PASS ✅ / FAIL ❌ / skipped |

**New tests written:** [yes: `path/to/test.rs: test_name` / no]

**Failure output** (if any):
[paste full failure output — not truncated]

---

### Visual Proof

**UI screenshots (inline — renders in Linear):**

![Step 1 — Initial state]([url returned by create_attachment for step-1])
![Step 2 — Happy path]([url returned by create_attachment for step-2])
![Step 3 — Error state]([url returned by create_attachment for step-3])

| # | Filename | What it shows |
|---|---|---|
| 1 | `step-1-initial-state.png` | [description] |
| 2 | `step-2-happy-path.png` | [description] |
| 3 | `step-3-error-state.png` | [description] |

**Console errors found:** [none / list exact error text]

**API responses** (backend tickets — full JSON inline):

`[METHOD] /[endpoint]` — [criterion] — happy path (HTTP [status]):
```json
[paste full response JSON]
```

`[METHOD] /[endpoint]` — [criterion] — error case (HTTP [status]):

```json
[paste full response JSON]
```

**All proof uploaded to Linear:** [yes / no — FAIL reason if no]

---

### Code Review Findings

[Specific file:line concerns. If none: "No issues found."]

---

### Reproduction Steps (FAIL only)

To reproduce the failure immediately:

1. [exact step]
2. [exact step]

**Expected:** [x]
**Actual:** [y]

---

### Verdict

**[PASS — moving to Human Review ✅ / FAIL — moving to Changes Required ❌]**

[1–2 sentences: why.]

```

After posting the review comment, write the review artifact:

```bash
mkdir -p "thoughts/tickets/{{ARGUMENTS}}"
```

Write to `thoughts/tickets/{{ARGUMENTS}}/review.md`:

```markdown
---
ticket: {{ARGUMENTS}}
branch: [branch name]
reviewed: [ISO date]
verdict: [PASS / FAIL]
status_after: [Human Review / Changes Required]
tests_passed: [yes / no]
scope_discrepancy: [none / minor / significant]
---

## Verdict
[PASS ✅ / FAIL ❌] — [1–2 sentences why]

## Test Results Summary
[copy from test results table]

## Scope Validation
[none / list discrepancies found]

## Failures (FAIL only)
[copy reproduction steps and root cause]
```

---

## Phase 7 — Update Linear Status

Resolve the git user email:

```bash
GIT_EMAIL=$(git config user.email)
```

**PASS → Human Review:**

```bash
# Find "In Review" or "Human Review" status ID
# mcp__linear-server__save_issue → { id, statusId: <human_review_id>, assignee: "<GIT_EMAIL>" }
```

**FAIL → Changes Required:**

```bash
# Find "Changes Required" status ID (fall back to "Backlog" if not found)
# mcp__linear-server__save_issue → { id, statusId: <changes_required_id>, assignee: "<GIT_EMAIL>" }
```

---

## Phase 8 — Hand Off

**FAIL path** — stop immediately:

Inform the user:
> "Review FAILED for {{ARGUMENTS}}. Moved to Changes Required. See the Linear comment for full details and reproduction steps."

The implementation worktree (`${WORKTREE}`) is **not touched** — it stays for the implementer to pick up and fix.

**PASS path** — leave the system running and inform the user:

```
AskUserQuestion:
  "Review PASSED for {{ARGUMENTS}} — ready for human verification.

  The system is still running:
    Frontend:  http://localhost:8105
    Starfish:  http://localhost:8101/swagger
    Keeper:    http://localhost:8104

  Full review report posted to Linear ticket {{ARGUMENTS}}."
```

---

## Phase 9 — No Clean Up Required

The worktree used for review is the implementation worktree — it is owned by `/ticket-process` and kept for any follow-up fixes or for `/ticket-approve`. Do not remove it.

---

## Status Transition Map

```
Review Pending  →  In Review        (Phase 1, on claim)
In Review       →  Human Review     (PASS: all tests green, criteria met)
In Review       →  Changes Required (FAIL: any test red, criteria missed)
```

## Evidence Standards

The bar for documentation: **a fresh agent reading only the ticket + its comments must reproduce any failure in under 2 minutes.**

Required in every review comment:

- Full test output (not paraphrased — paste the actual output)
- Screenshots rendered as inline `![alt](url)` images so they display in Linear without clicking
- API JSON responses embedded as fenced code blocks in the comment body
- Exact console error text (not summarised)
- `file:line` for every code concern raised
- Exact reproduction steps written as numbered CLI/UI actions

## Worktree Convention

| Attribute | Value |
|---|---|
| Implementation branch | `feat/{{ARGUMENTS}}` or `fix/{{ARGUMENTS}}` |
| Worktree | `../worktrees/feat/{{ARGUMENTS}}` (shared — created by `/ticket-process`, reused by this command) |
| Managed by | `wtp` |
| Lifecycle | Created by `/ticket-process` → reused for review → removed by `/ticket-approve` |

## Critical Rules

1. **Never skip Phase 0** — always read existing comments before doing anything; don't re-do already completed work
2. **Never mark PASS without running tests** — if tests can't run, document why and mark FAIL
3. **Write missing tests** — if the changed behavior has no test, add it before judging
4. **Visual proof is mandatory — no exceptions** — there is no "backend-only skip"; API tickets use curl proof files instead of screenshots. A PASS with an empty proof directory is invalid. **Local file existence is not proof — always verify via `get_issue` that Linear shows non-zero attachments.**
5. **Proof must be readable in-app** — screenshots embedded as `![alt](url)` inline images; API responses as fenced code blocks in the comment body. Never rely on attachments alone.
6. **One comprehensive comment** — post a single review report, not incremental updates
7. **Never remove the worktree** — it is shared with `/ticket-process` and `/ticket-approve`; only `/ticket-approve` removes it
8. **NEVER move a ticket to Done** — the only valid PASS destination is `Human Review`. Done requires explicit human approval. Moving to Done is forbidden regardless of test results.

## Orchestration Map

```
/ticket-review GYL-XX
        │
        ▼
Phase 0: Find implementation branch from Linear comments
  get_issue + list_comments [parallel]
        │
        ├── no branch? → save_comment + Changes Required → exit
        │
        ▼
Phase 1: Locate implementation worktree
  wtp ls | grep feat/GYL-XX  (reuse existing impl worktree)
  → ../worktrees/feat/GYL-XX  (shared with /ticket-process)
        │
        ▼
Phase 2: Understand implementation
  git log develop..HEAD + read thoughts/ artifacts
  extract claimed files from completion comment
        │
        ├── no commits? → save_comment + Changes Required → exit
        │
        ▼
Phase 2b: Validate Against Git Ground Truth
  git diff develop...HEAD --name-only (actual)
  vs. claimed files from completion comment
  flag: claimed-but-missing, undeclared-scope-changes
        │
        ▼
Phase 3: Code Review
  Explore agent (quick) scoped to changed files
        │
        ▼
Phase 4: Tests [parallel where independent]
  ┌──────────────────────────────────────────┐
  │ cargo test --all (Rust changes)          │
  │ cd keeper && npm test (TS changes)       │
  │ pnpm lint+build (frontend changes)       │
  │ Write + commit new tests if gaps found   │
  └──────────────────────┬───────────────────┘
                         │
                         ▼
Phase 5: Visual Proof [MANDATORY — no skip]
  ┌──────────────────────────────────────────────────┐
  │ UI tickets:                                      │
  │   new_page → navigate :8105                      │
  │   take_screenshot per acceptance criterion       │
  │   base64 → create_attachment → record url        │
  │   → /tmp/screenshots/GYL-XX-review/step-N-*.png  │
  │                                                  │
  │ API/backend tickets:                             │
  │   curl happy path + error case per criterion     │
  │   base64 → create_attachment on Linear           │
  │   → /tmp/screenshots/GYL-XX-review/api-*.json    │
  │                                                  │
  │ verify: get_issue attachment count matches       │
  │ Empty proof dir = FAIL — AskUserQuestion         │
  └──────────────────────┬───────────────────────────┘
                         │
                         ▼
Phase 6: Verdict + Review Comment
  save_comment: tests + ![img](url) previews + JSON code blocks
  write: thoughts/tickets/{{ARGUMENTS}}/review.md
                         │
               ┌─────────┴──────────┐
             PASS                 FAIL
               │                   │
               ▼                   ▼
Phase 7: Update Linear Status
  save_issue: Human Review   save_issue: Changes Required
               │                   │
               ▼                   ▼
Phase 8: Hand Off
  AskUserQuestion:           Inform user: FAILED
  "PASSED — verify at        (worktree kept for implementer)
   localhost:8105."
               │
               ▼
Phase 9: No clean up — worktree owned by /ticket-process
  (removed only by /ticket-approve)
```
