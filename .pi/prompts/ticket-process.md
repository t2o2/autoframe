---
description: Autonomously process a Linear ticket end-to-end in an isolated git worktree (fetch → claim → implement → close)
argument-hint: "<ticket-id>"
---

Autonomously pick up a Linear ticket, implement it in an **isolated git worktree managed by `wtp`**, and update its status throughout the lifecycle. Safe to run in parallel with other ticket agents — each ticket gets its own branch and worktree.

## Request

Ticket ID: $ARGUMENTS

---

## Linear API

Use the Linear GraphQL API via bash for all ticket operations. The `LINEAR_API_KEY` environment variable is available.

```bash
# Helper — run a Linear GraphQL query/mutation
linear_gql() {
    local query="$1"
    curl -sf \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"query\": $(echo "$query" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
        https://api.linear.app/graphql
}
```

Key queries/mutations you will need:

**Get issue:**
```bash
linear_gql '{ issue(id: "TICKET_ID") { id title description priority labels { nodes { name } } state { id name } team { id key } assignee { email } } }'
# Or by identifier:
linear_gql '{ issues(filter:{identifier:{eq:"GYL-123"}}) { nodes { id title description priority labels { nodes { name } } state { id name } team { id key } } } }'
```

**List workflow states:**
```bash
linear_gql '{ workflowStates(filter:{team:{key:{eq:"GYL"}}}) { nodes { id name } } }'
```

**List comments:**
```bash
linear_gql '{ issue(id: "ISSUE_UUID") { comments { nodes { body createdAt } } } }'
```

**Update issue (status / assignee):**
```bash
linear_gql 'mutation { issueUpdate(id: "ISSUE_UUID", input: { stateId: "STATE_UUID", assigneeId: "USER_UUID" }) { success } }'
```

**Post comment:**
```bash
linear_gql 'mutation { commentCreate(input: { issueId: "ISSUE_UUID", body: "comment text" }) { success comment { id } } }'
```

**Upload attachment** (screenshots / API proof):
```bash
# Step 1 — request presigned upload URL
UPLOAD=$(linear_gql 'mutation { fileUpload(contentType: "image/jpeg", size: FILE_SIZE, filename: "proof.jpg") { uploadFile { uploadUrl assetUrl headers { key value } } } }')
UPLOAD_URL=$(echo "$UPLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$UPLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['fileUpload']['uploadFile']['assetUrl'])")
# Step 2 — PUT the file
curl -sf -X PUT -H "Content-Type: image/jpeg" --data-binary @/path/to/file.jpg "$UPLOAD_URL"
# Step 3 — create attachment linking asset URL to the issue
linear_gql "mutation { attachmentCreate(input: { issueId: \"ISSUE_UUID\", url: \"$ASSET_URL\", title: \"Proof title\" }) { success } }"
```

**Get current user (for assignee):**
```bash
linear_gql '{ viewer { id email } }'
```

---

## Browser Automation

Use the native `agent_browser` tool for all browser interactions (screenshots, UI testing):

```
agent_browser open http://localhost:8105
agent_browser snapshot -i
agent_browser screenshot /tmp/screenshots/step-1.jpg --format jpeg --quality 70
agent_browser click "@e3"              # use ref from snapshot
agent_browser fill "@e5" "some text"
agent_browser eval --stdin             # with stdin: JS expression to evaluate
```

Key workflow: `open URL` → `snapshot -i` → interact using `@ref` labels → `screenshot path`.

---

## Phase 0 — Worktree Setup

**This must be the very first action, before any file reads or code changes.**

First, fetch the ticket to determine the branch prefix (bug → `fix/`, feature → `feat/`):

```bash
# After fetching ticket type from Linear (done in Phase 1),
# determine branch name:
TICKET="$ARGUMENTS"
BRANCH_TYPE="feat"  # or "fix" based on ticket labels — set this first

BRANCH="${BRANCH_TYPE}/${TICKET}"   # e.g. feat/GYL-15
WORKTREE="../worktrees/${BRANCH}"   # e.g. ../worktrees/feat/GYL-15
```

Pull the latest base branch from remote before branching:

```bash
BASE_BRANCH="${GIT_BASE_BRANCH:-develop}"
git fetch origin "$BASE_BRANCH"
```

Check if worktree already exists (idempotent — supports resuming interrupted work):

```bash
if wtp ls 2>/dev/null | grep -q "${BRANCH}"; then
  echo "Resuming existing worktree for ${BRANCH}"
else
  wtp add -b "${BRANCH}" "origin/${BASE_BRANCH}"
  echo "Created worktree at ${WORKTREE}"
fi
```

Verify the worktree path:

```bash
command wtp cd "${BRANCH}"   # prints absolute path — confirm it matches expectations
```

> All subsequent file operations **must use `$WORKTREE` as the base path**, not the main repo directory.

---

## Phase 0.5 — Resumption Check

Before fetching the ticket from Linear, check if prior work exists for this ticket:

```bash
HANDOFF="thoughts/tickets/$ARGUMENTS/handoff.md"
PLAN_ARTIFACT="thoughts/tickets/$ARGUMENTS/plan.md"

if [ -f "$HANDOFF" ]; then
  echo "=== Prior handoff found for $ARGUMENTS ==="
  cat "$HANDOFF"
  echo ""
  echo "Checking git state..."
  HANDOFF_COMMIT=$(grep '^git_commit:' "$HANDOFF" | awk '{print $2}')
  CURRENT_COMMIT=$(cd "${WORKTREE}" && git rev-parse HEAD 2>/dev/null || echo "unknown")
  echo "Handoff commit : $HANDOFF_COMMIT"
  echo "Current HEAD   : $CURRENT_COMMIT"
fi
```

**If a handoff exists:**

- Read `last_completed_phase` from the handoff YAML frontmatter
- Read `git_commit` and compare to current `HEAD` in the worktree
- If commits match: skip all phases up to and including `last_completed_phase`, resume from the next phase
- If commits differ: note the divergence, start from Phase 3 (re-explore, don't re-implement)
- Post a comment: *"Resuming $ARGUMENTS from Phase [N+1]. Prior work detected in worktree — [1 sentence on what was already done]."*

**If no handoff exists:** proceed normally from Phase 1.

---

## Phase 1 — Fetch & Analyze

Fetch everything using the Linear GraphQL API (see **Linear API** section above):

1. Get full issue details by identifier (`$ARGUMENTS`)
2. List all workflow states for the team
3. List comments on the issue

**Check thought store for plan artifact:**

```bash
PLAN_ARTIFACT="thoughts/tickets/$ARGUMENTS/plan.md"
if [ -f "$PLAN_ARTIFACT" ]; then
  echo "Plan artifact found — reading approved phase checklist"
else
  echo "No plan artifact — will find plan in Linear comments"
fi
```

Parse and record:

- **Title**, **description**, **priority**, **labels**, **current status**, **team ID**, **issue UUID**
- **Type**: Bug (labels: Bug / title starts with fix/bug) → `fix/` branch; Feature/Improvement → `feat/` branch

**Dependency Check (child/sibling tickets):**

If the ticket has a parent, fetch the parent and its children. For any sibling in `Todo`/`Backlog` that is a prerequisite, automatically restart with the prerequisite ticket ID first.

If description is too vague (< 2 actionable sentences): post a comment asking for clarification and raise via the `ask_user_question` tool if available.

---

## Phase 2 — Claim the Ticket

**Always run this phase.**

1. Find "In Progress" state UUID from Phase 1 results
2. Get current user UUID: `linear_gql '{ viewer { id email } }'`
3. Update issue: set state to In Progress, assign to current user
4. Post comment:
   > "Picked up in isolated worktree on branch `feat/$ARGUMENTS`. Plan: [1–3 sentence summary]. Changes are isolated to this branch — nothing touches `develop` until pushed."
5. Write initial handoff artifact to `thoughts/tickets/$ARGUMENTS/handoff.md`

---

## Phase 3 — Explore & Plan

All exploration reads code from the worktree path (`$WORKTREE`).

**Bug tickets**: Spawn `bug-investigator` subagent — provide title, description, error messages, and the worktree path as the code root

**Feature/Improvement tickets**: Spawn `Explore` subagent + `Plan` subagent

If a key architectural decision surfaces, post a comment with the decision and rationale.

---

## Phase 4 — Implement

Spawn `senior-implementer` subagent with:

- Full ticket description
- Plan/investigation output from Phase 3
- The worktree absolute path as the working directory
- Instruction: follow TDD (red → green → refactor), all changes stay inside `$WORKTREE`

If a blocker is hit: post a Linear comment describing the blocker, then raise via `ask_user_question` if available.

After implementer completes, update `thoughts/tickets/$ARGUMENTS/handoff.md` with `last_completed_phase: 4` and the current git commit.

---

## Phase 5a — Automated Tests

Run test suites **from the worktree path**. Run all that apply:

```bash
# Rust
cd "${WORKTREE}" && cargo test --all 2>&1

# Keeper / TypeScript
cd "${WORKTREE}/keeper" && npm test 2>&1

# Frontend
cd "${WORKTREE}/frontend-issuance" && pnpm lint && pnpm build 2>&1 | tail -30
```

If tests fail: attempt to fix (up to 2 iterations). After 2 failed attempts, post a comment with full output and raise.

Update handoff: `last_completed_phase: "5a"`.

---

## Phase 5b — Visual Proof (Mandatory)

**Every ticket requires proof uploaded to Linear. No ticket moves to Review Pending without it.**

```bash
PROOF_DIR="/tmp/screenshots/$ARGUMENTS"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets (changes under `frontend-issuance/`)

Use `agent_browser` for all browser interactions:

```
agent_browser open http://localhost:8105
agent_browser snapshot -i
```

Walk through **every acceptance criterion** that has a visible outcome. For each step:

1. Perform the action using `agent_browser` (click, fill, navigate)
2. Take a screenshot: `agent_browser screenshot ${PROOF_DIR}/step-N-description.jpg --format jpeg --quality 70`
3. Check for console errors: `agent_browser eval --stdin` with `JSON.stringify([...document.querySelectorAll('.error')].map(e => e.textContent))`

Upload each screenshot to Linear using the upload workflow in the **Linear API** section.
Record the returned `assetUrl` for each file — embed as inline markdown images in the Phase 6 completion comment.

**Minimum required screenshots:**

| State | Filename |
|---|---|
| Feature page on load | `step-1-initial-state.jpg` |
| Happy path end state | `step-2-happy-path.jpg` |
| Error / validation state | `step-3-error-state.jpg` |

If the frontend fails to start: raise via `ask_user_question` before proceeding — never silently skip.

### API / Backend Tickets (no frontend changes)

Run real curl commands against live local services. For each acceptance criterion:

```bash
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' \
  -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' \
  -d '[request body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-proof-[criterion]-happy.json"
```

Upload each JSON file to Linear using the attachment upload workflow. Embed full JSON inline in the Phase 6 comment.

**Verify uploads:**

```bash
# Confirm attachments count via Linear API
linear_gql '{ issue(id: "ISSUE_UUID") { attachments { nodes { id title } } } }'
```

Count must match number of uploaded files. Re-upload any missing ones.

---

## Phase 6 — Commit, Push & Hand Off

1. Commit all changes inside the worktree:

```bash
cd "${WORKTREE}"
git add -A
git commit -m "$ARGUMENTS: feat: [short description matching ticket title]

- [what changed and why]

Fixes $ARGUMENTS"
```

2. Push the branch:

```bash
cd "${WORKTREE}" && git push -u origin "${BRANCH}"
```

3. Update ticket status to "Review Pending" (or "Done" if self-contained):
   Use `issueUpdate` mutation with the appropriate state UUID.

4. Post completion comment — **include the branch name so `/ticket-review` can find it**:

```
Implementation complete.

**Branch:** `feat/$ARGUMENTS`

**Changes:**
- [file path: what changed and why]

**Tests:** [summary]

**Proof:** (attachments uploaded to this ticket)
- 📸 step-1-initial-state.jpg
- 📸 step-2-happy-path.jpg

**Screenshots (inline):**
![Step 1](asset_url_1)
![Step 2](asset_url_2)

**Next step:** `/ticket-review $ARGUMENTS`
```

5. Worktree stays — **do not remove it**. The reviewer needs the branch to run tests.

---

## Worktree Convention

| Attribute | Value |
|---|---|
| Bug branch | `fix/$ARGUMENTS` |
| Feature branch | `feat/$ARGUMENTS` |
| Worktree path | `../worktrees/<branch>` |
| Managed by | `wtp` |
| Lifecycle | Created in Phase 0, kept after Phase 6 |

## Status Transitions

```
Backlog / Todo  →  In Progress      (Phase 2)
In Progress     →  Review Pending   (Phase 6, PR path)
In Progress     →  Done             (Phase 6, self-contained)
```

## Critical Rules

1. **Phase 0 first** — `wtp add` before any file operation
2. **All paths use `$WORKTREE`** — never read or write files in the main repo during implementation
3. **Never work on `develop` directly**
4. **Push before handing off** — `/ticket-review` needs the branch on origin
5. **Record branch name in completion comment** — the reviewer reads this to find the branch
6. **Do not remove the worktree** — it persists for `/ticket-review`
7. **Visual proof is mandatory** — Phase 5b cannot be skipped
