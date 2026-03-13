---
description: Autonomously process a Linear ticket end-to-end in an isolated git worktree (fetch → claim → implement → close)
runInPlanMode: false
scope: project
---

Autonomously pick up a Linear ticket, implement it in an **isolated git worktree managed by `wtp`**, and update its status throughout the lifecycle. Safe to run in parallel with other ticket agents — each ticket gets its own branch and worktree.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Worktree Setup

**This must be the very first action, before any file reads or code changes.**

First, fetch the ticket to determine the branch prefix (bug → `fix/`, feature → `feat/`):

```bash
# After fetching ticket type from Linear (done in Phase 1),
# determine branch name:
TICKET="{{ARGUMENTS}}"
BRANCH_TYPE="feat"  # or "fix" based on ticket labels — set this first

BRANCH="${BRANCH_TYPE}/${TICKET}"   # e.g. feat/TICKET-15
WORKTREE="../worktrees/${BRANCH}"   # e.g. ../worktrees/feat/TICKET-15
```

Check if worktree already exists (idempotent — supports resuming interrupted work):

```bash
if wtp ls 2>/dev/null | grep -q "${BRANCH}"; then
  echo "Resuming existing worktree for ${BRANCH}"
  # Worktree already exists — continue from where work left off
else
  wtp add -b "${BRANCH}"
  echo "Created worktree at ${WORKTREE}"
fi
```

Verify the worktree path:

```bash
command wtp cd "${BRANCH}"   # prints absolute path — confirm it matches expectations
```

> All subsequent file operations (Read, Edit, Write, Bash, tests) **must use `$WORKTREE` as the base path**, not the main repo directory. The worktree has the same codebase as the main branch at branch point but is fully isolated.

---

## Phase 1 — Fetch & Analyze

Fetch everything in parallel:

1. `mcp__linear-server__get_issue` — full ticket details
2. `mcp__linear-server__list_issue_statuses` — valid status IDs for the team
3. `mcp__linear-server__list_comments` — prior discussion and previous attempt notes

Parse and record:

- **Title**, **description**, **priority**, **labels**, **current status**, **team ID**
- **Type**: Bug (labels: Bug / title starts with fix/bug) → `fix/` branch; Feature/Improvement → `feat/` branch
- Use the type to set `BRANCH_TYPE` in Phase 0 before creating the worktree

**Dependency Check (child/sibling tickets):**

If the ticket has a `parent` field, it is a child ticket. Fetch the parent issue and list its children (siblings of this ticket):

- For each sibling (excluding this ticket itself), check its status
- Identify any siblings that are in `Todo`/`Backlog` state that this ticket **depends on** (i.e., the sibling is described as a prerequisite in the parent description, or the sibling's title/description indicates it must come first — e.g., "Part 1", "Step 1", schema migration before feature, etc.)
- If a blocking sibling is found and has not been started, **automatically restart this entire skill with the prerequisite ticket ID** — do not ask, just process the prerequisite first, then return and process {{ARGUMENTS}} afterward
- If siblings are independent or all prerequisites are already Done/In Review, continue normally
- If no parent exists (top-level ticket), skip this check

If description is too vague (< 2 actionable sentences):

- Post comment: *"Picking up {{ARGUMENTS}} in isolated worktree. Description needs clarification before I can proceed — [specific question]."*
- Use `AskUserQuestion` to gather context, then continue

---

## Phase 2 — Claim the Ticket

1. Find "In Progress" status ID from Phase 1 results
2. Resolve the git user email to use as the Linear assignee:

   ```bash
   GIT_EMAIL=$(git config user.email)
   ```

3. `mcp__linear-server__save_issue` → `{ id, statusId: <in_progress_id>, assignee: "<GIT_EMAIL>" }`
4. `mcp__linear-server__save_comment`:
   > "Picked up in isolated worktree on branch `feat/{{ARGUMENTS}}`. Plan: [1–3 sentence summary]. Changes are isolated to this branch — nothing touches the main branch until pushed."

---

## Phase 3 — Explore & Plan

All exploration reads code from the worktree path (`$WORKTREE`), which mirrors the main branch.

**Bug tickets**: Launch `bug-investigator` agent — provide title, description, error messages, and the worktree path as the code root

- Capture: root cause hypothesis, affected files, reproduction path

**Feature/Improvement tickets**: Launch `Explore` agent (medium thoroughness) + `Plan` agent

- `Explore`: map relevant code areas from the ticket description
- `Plan`: design implementation using exploration findings

**Ambiguous**: `AskUserQuestion` → "Is this a bug fix or a new feature?"

If a key architectural decision surfaces, post a comment:
> "Key decision in {{ARGUMENTS}}: [decision + rationale]. Proceeding with this approach."

---

## Phase 4 — Implement

Launch `senior-implementer` agent with:

- Full ticket description
- Plan / investigation output from Phase 3
- The worktree absolute path as the working directory
- Instruction: follow TDD (red → green → refactor), all changes stay inside `$WORKTREE`

If a blocker is hit during implementation:

1. `mcp__linear-server__save_comment`: *"Blocked in `feat/{{ARGUMENTS}}`: [blocker]. [Proposed resolution]."*
2. `AskUserQuestion` to unblock, then resume

---

## Phase 5a — Automated Tests

Run test suites **from the worktree path**. Adapt commands to your project's tech stack:

```bash
# Example: run your project's test suite from the worktree
cd "${WORKTREE}" && <your test command> 2>&1
```

Common patterns:
- Rust: `cargo test --all`
- Node.js/TypeScript: `npm test` or `pnpm test`
- Python: `pytest`
- Go: `go test ./...`

If tests fail: attempt to fix (up to 2 iterations). After 2 failed attempts, post a comment with full output and `AskUserQuestion`.

---

## Phase 5b — Visual Proof (Mandatory)

**Every ticket requires proof that the implemented behaviour actually works. No ticket moves to Review Pending without it. All proof must be uploaded to the Linear ticket — not just saved locally.**

Set the proof directory:

```bash
PROOF_DIR="/tmp/screenshots/{{ARGUMENTS}}"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets (any frontend changes)

Ensure the frontend and its backing services are running. Then use Chrome DevTools MCP:

1. `mcp__chrome-devtools__new_page` — open a fresh tab
2. `mcp__chrome-devtools__navigate_page` → your local frontend URL
3. `mcp__chrome-devtools__list_console_messages` — capture baseline (no pre-existing errors)

Walk through **every acceptance criterion** that has a visible outcome. For each step:

- Perform the action (click, fill form, submit, etc.)
- `mcp__chrome-devtools__take_screenshot` → save to `${PROOF_DIR}/step-N-[description].png`
- `mcp__chrome-devtools__list_console_messages` — confirm no new errors
- **Immediately upload the screenshot to Linear:**

  ```bash
  SCREENSHOT_B64=$(base64 -i "${PROOF_DIR}/step-N-[description].png")
  ```

  Then call `mcp__linear-server__create_attachment`:
  - `issue`: `{{ARGUMENTS}}`
  - `base64Content`: the base64 string from above
  - `filename`: `step-N-[description].png`
  - `contentType`: `image/png`
  - `title`: `[Step N] [Short description of what is shown]`
  - `subtitle`: `{{ARGUMENTS}} — implementation proof`

  **Record the `url` returned by each `create_attachment` call.** You will embed these as inline markdown images in the Phase 6 completion comment so reviewers see previews directly in Linear without downloading.

**Minimum required screenshots (all must be uploaded):**

| State | Filename | Linear attachment title |
|---|---|---|
| Feature page on load | `step-1-initial-state.png` | `[Step 1] Initial state` |
| Happy path end state | `step-2-happy-path.png` | `[Step 2] Happy path — feature working` |
| Error / validation state | `step-3-error-state.png` | `[Step 3] Error/validation state` |
| Each additional criterion | `step-N-[criterion].png` | `[Step N] [Criterion description]` |

If the Chrome DevTools MCP tool fails — try `mcp__chrome-devtools__new_page` to open a fresh context and retry once. If that also fails, **raise via `AskUserQuestion`** — never silently skip screenshots for UI tickets.

### API / Backend Tickets (no frontend changes)

Run real curl commands against the live local services. For each acceptance criterion:

```bash
# Adapt method, path, headers, and body to the actual endpoint
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' \
  -X POST http://localhost:<port>/[endpoint] \
  -H 'Content-Type: application/json' \
  -d '[request body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-proof-[criterion]-happy.json"
```

Capture proof for:

- The **happy path** — expected success response with HTTP status
- At least one **error/validation case** — bad input or missing auth
- Any **state change** — confirm with a follow-up GET

**Upload each JSON response as a Linear attachment:**

```bash
API_B64=$(base64 -i "${PROOF_DIR}/api-proof-[criterion]-happy.json")
```

Then call `mcp__linear-server__create_attachment`:

- `issue`: `{{ARGUMENTS}}`
- `base64Content`: the base64 string
- `filename`: `api-proof-[criterion]-happy.json`
- `contentType`: `application/json`
- `title`: `[API] [Criterion] — happy path`
- `subtitle`: `{{ARGUMENTS}} — implementation proof`

**Also embed the full JSON inline in the completion comment** (see Phase 6) so reviewers can read it without downloading.

### Confirm All Attachments Uploaded

**Step 1 — verify files exist locally:**

```bash
ls -la "${PROOF_DIR}/"
```

**Step 2 — verify uploads reached Linear (mandatory):**

Call `mcp__linear-server__get_issue` with the issue UUID (from Phase 1) and confirm `attachments` is non-empty. The count must equal the number of files you uploaded. If the count is lower than expected, re-call `mcp__linear-server__create_attachment` for any missing files and re-check until counts match.

Local file existence alone is not sufficient — only a non-zero `attachments` count in Linear confirms reviewers can see the proof.

---

## Phase 6 — Commit, Push & Hand Off

1. Commit all changes inside the worktree:

   ```bash
   cd "${WORKTREE}"
   git add -A
   git commit -m "$(cat <<'EOF'
   {{ARGUMENTS}}: feat: [short description matching ticket title]

   - [what changed and why]
   - [what changed and why]

   Fixes {{ARGUMENTS}}
   EOF
   )"
   ```

2. Push the branch to origin:

   ```bash
   cd "${WORKTREE}" && git push -u origin "${BRANCH}"
   ```

3. Update ticket status:
   - Changes pushed, review needed → find "Review Pending" status ID → `mcp__linear-server__save_issue`
   - Self-contained and complete → find "Done" status ID → `mcp__linear-server__save_issue`

4. Post completion comment — **include the branch name so `/ticket-review` can find it**:

   ```
   Implementation complete.

   **Branch:** `feat/{{ARGUMENTS}}`
   **Worktree:** `../worktrees/feat/{{ARGUMENTS}}`

   **Changes:**
   - [file path: what changed and why]
   - [file path: what changed and why]

   **Tests:** [summary — suites run, pass/fail counts]

   **Proof of working behaviour** (attachments uploaded to this ticket):
   - [list every uploaded attachment filename with a brief description]

   **Screenshots (inline previews):**
   ![Step 1 — Initial state]([url from create_attachment for step-1])
   ![Step 2 — Happy path]([url from create_attachment for step-2])
   ![Step 3 — Error state]([url from create_attachment for step-3])

   **API responses** (if backend ticket — embed full JSON inline):

   `POST /[endpoint]` — happy path (HTTP [status]):
   ```json
   [paste full response JSON]
   ```

   **Console errors during testing:** [none / list exact error text]

   **Next step:** `/ticket-review {{ARGUMENTS}}`

   ```

5. Worktree stays — **do not remove it**. The reviewer needs the branch to run tests:

   ```bash
   # Confirm worktree is still registered
   wtp ls | grep "{{ARGUMENTS}}"
   ```

## Worktree Convention

| Attribute | Value |
|---|---|
| Bug branch | `fix/{{ARGUMENTS}}` |
| Feature branch | `feat/{{ARGUMENTS}}` |
| Worktree path | `../worktrees/<branch>` |
| Managed by | `wtp` (status: managed) |
| Lifecycle | Created in Phase 0, kept after Phase 6 for review |

## Status Transitions

```
Backlog / Todo  →  In Progress      (Phase 2)
In Progress     →  Review Pending   (Phase 6, PR path)
In Progress     →  Done             (Phase 6, self-contained)
```

## Critical Rules

1. **Phase 0 first** — `wtp add` before any file operation
2. **All paths use `$WORKTREE`** — never read or write files in the main repo during implementation
3. **Never work on the main branch directly** — the worktree branch is the blast radius boundary
4. **Push before handing off** — `/ticket-review` needs the branch on origin
5. **Record branch name in completion comment** — the reviewer reads this to find the branch
6. **Do not remove the worktree** — it persists for `/ticket-review`
7. **Visual proof is mandatory** — Phase 5b cannot be skipped; every ticket must have at least one screenshot or API response file uploaded to Linear before commit

## Orchestration Map

```
/ticket-process TICKET-XX
        │
        ▼
Phase 0: wtp add -b feat/TICKET-XX
  → ../worktrees/feat/TICKET-XX (isolated, managed by wtp)
        │
        ▼
Phase 1: Fetch & Analyze [parallel]
  get_issue + list_issue_statuses + list_comments
        │
        ├── child ticket? → fetch parent + siblings → check prerequisites
        │     └── blocking sibling not started? → restart with prereq ticket ID first
        │
        ├── vague? → save_comment + AskUserQuestion
        │
        ▼
Phase 2: Claim
  save_issue: In Progress
  save_comment: branch name + plan
        │
        ▼
Phase 3: Explore & Plan [inside worktree]
  ┌─────────────────────────┐
  │ bug-investigator (bug)  │
  │ Explore + Plan (feat)   │
  └────────────┬────────────┘
               │
               ├── key decision? → save_comment
               │
               ▼
Phase 4: Implement [cd $WORKTREE]
  senior-implementer agent
               │
               ├── blocker? → save_comment + AskUserQuestion
               │
               ▼
Phase 5a: Automated Tests [cd $WORKTREE]
  <project test suite>
               │
               ├── fail? → fix (×2) → save_comment + AskUserQuestion
               │
               ▼
Phase 5b: Visual Proof [MANDATORY]
  ┌─────────────────────────────────────────────────┐
  │ UI tickets:                                     │
  │   new_page → navigate frontend URL              │
  │   take_screenshot per acceptance criterion      │
  │   base64 encode → create_attachment on Linear   │
  │   record returned url for inline previews       │
  │                                                 │
  │ API/backend tickets:                            │
  │   curl happy path + error case                  │
  │   base64 encode → create_attachment on Linear   │
  │                                                 │
  │ verify: get_issue attachments count matches     │
  └──────────────────────┬──────────────────────────┘
               │
               ├── frontend won't start? → AskUserQuestion (never skip)
               │
               ▼
Phase 6: Commit + Push + Hand Off
  git commit + git push origin feat/TICKET-XX
  save_issue: Review Pending / Done
  save_comment: branch name + changes + proof filenames + inline image previews
  [worktree kept for /ticket-review]
```
