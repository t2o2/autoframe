---
description: Autonomously process a Linear ticket end-to-end in an isolated git worktree (fetch → claim → implement → close)
runInPlanMode: false
scope: project
---

Process a Linear ticket: fetch → claim → implement → test → proof → push. Each ticket gets its own worktree branch. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Claim & Worktree Setup

**Claim immediately — before any other work.**

Fetch in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}"
bash ~/.agents/skills/linear/list-states.sh
```

Determine branch type (Bug → `fix/`, else → `feat/`):
```bash
TICKET="{{ARGUMENTS}}"
BRANCH_TYPE="feat"  # or "fix"
BRANCH="${BRANCH_TYPE}/${TICKET}"
WORKTREE="../worktrees/${BRANCH}"
```

Claim:
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <in_progress_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Picking up {{ARGUMENTS}} on branch \`${BRANCH}\`."
```

Set up worktree:
```bash
git fetch origin "${GIT_BASE_BRANCH:-develop}"
if wtp ls 2>/dev/null | grep -q "${BRANCH}"; then
  echo "Resuming existing worktree"
else
  wtp add -b "${BRANCH}" "origin/${GIT_BASE_BRANCH:-develop}"
fi
```

> All subsequent file operations **must use `$WORKTREE`** as the base path.

Write initial handoff to `thoughts/tickets/{{ARGUMENTS}}/handoff.md` with: ticket, branch, git_commit, last_completed_phase: 0, date, status: in_progress.

---

## Phase 1 — Resumption Check

```bash
HANDOFF="thoughts/tickets/{{ARGUMENTS}}/handoff.md"
```

- If handoff exists and commits match → skip to `last_completed_phase + 1`
- If commits differ → start from Phase 3 (re-explore, don't re-implement)
- If no handoff → proceed to Phase 2

---

## Phase 2 — Deep Analysis

Check for plan artifact first (preferred over comment parsing):
```bash
PLAN_ARTIFACT="thoughts/tickets/{{ARGUMENTS}}/plan.md"
[ -f "$PLAN_ARTIFACT" ] && echo "Plan artifact found" || echo "No plan — checking comments"
```

Parse from Phase 0: title, description, priority, labels, status, team ID. Confirm branch type.

**Dependency check:** If ticket has a parent, fetch siblings. If a prerequisite sibling is in Todo/Backlog, process it first automatically.

If description too vague (< 2 actionable sentences): ask via `./scripts/ask-human.sh {{ARGUMENTS}} "<question>" "<opt1>" "<opt2>"` (it @-mentions the ticket owner on Linear and waits for a reply). Use `AskUserQuestion` only in an attended/interactive session.

---

## Phase 3 — Explore & Plan

All reads from `$WORKTREE`.

Read the cross-ticket lessons log and apply relevant prior learnings to the implementation approach:
```bash
cat "${WORKTREE}/thoughts/retrospectives/LESSONS.md" 2>/dev/null
```

- **Bug tickets**: Launch `bug-investigator` — capture root cause, affected files, repro path
- **Feature tickets**: Launch `Explore` + `Plan` agents — map relevant code, design implementation
- **Ambiguous**: `./scripts/ask-human.sh {{ARGUMENTS}} "Bug or feature?" "Bug" "Feature"` (@-mentions the owner; `AskUserQuestion` only when attended)

Post key decisions as comments.

---

## Phase 4 — Implement

Launch `senior-implementer` with: ticket description, plan from Phase 3, worktree path. Follow TDD (red → green → refactor). All changes in `$WORKTREE`.

On blockers: `./scripts/ask-human.sh {{ARGUMENTS}} "<blocker question>" [options...]` to @-mention the owner and wait (`AskUserQuestion` only when attended).

Update `handoff.md`: set `last_completed_phase: 4`.

---

## Phase 5 — Automated Tests

**Tests are not complete until screenshots or a screen recording of the test run are captured and will be attached to the Linear ticket. Text output alone is never sufficient evidence.**

Run from worktree:
```bash
cd "${WORKTREE}" && cargo test -j 2 --all -- --test-threads=2 2>&1
cd "${WORKTREE}/keeper" && npm test 2>&1
cd "${WORKTREE}/frontend-issuance" && pnpm lint && pnpm build 2>&1 | tail -30
```

**Evidence requirement (mandatory — feeds directly into Phase 6):**

- **UI/frontend changes**: start a screen recording before any browser interaction (`agent-browser record start "${PROOF_DIR}/test-run.webm"`), take a screenshot per acceptance criterion as it is exercised, stop recording after completion. Save to `${PROOF_DIR}/`.
- **API/backend changes**: save every `curl` response to `${PROOF_DIR}/` during test execution — not retroactively.
- Evidence files must exist in `${PROOF_DIR}/` before updating `handoff.md`. Missing evidence = Phase 5 is not complete.

Fix failures (up to 2 attempts). Update `handoff.md`: set `last_completed_phase: 5`.

---

## Phase 6 — Visual Proof (Mandatory)

**No ticket moves to Review Pending without proof uploaded to Linear.**

```bash
PROOF_DIR="/tmp/screenshots/{{ARGUMENTS}}"
mkdir -p "${PROOF_DIR}"
```

### UI Tickets (changes under `frontend-issuance/`)

Use Chrome DevTools MCP: `new_page` → `resize_page(1280,800)` **before navigate** → `navigate_page` → walk each acceptance criterion → `take_screenshot(jpeg, quality:70)` → save to `${PROOF_DIR}/step-N-desc.jpg`.

**Upload each screenshot to Linear GCS:**
1. `sips -Z 1200` to downscale
2. `source ~/.agents/skills/linear/_lib.sh` → `linear_gql` FileUpload mutation → get `uploadUrl` + `assetUrl`
3. `curl -X PUT` to upload
4. Record each `ASSET_URL_STEP_N` for the completion comment

Minimum: initial state, happy path, error state. If frontend unreachable or Chrome DevTools fails → `AskUserQuestion`.

### API / Backend Tickets

```bash
RESPONSE=$(curl -s -w '\n{"http_status":%{http_code}}' -X POST http://localhost:8104/[endpoint] \
  -H 'Content-Type: application/json' -d '[body]')
echo "${RESPONSE}" | tee "${PROOF_DIR}/api-proof-[criterion]-happy.json"
```

Capture: happy path, error case, state-change confirmation. API responses embedded as code blocks in completion comment.

### Verify

```bash
ls -la "${PROOF_DIR}/"
```
All proof must exist before proceeding. Re-capture if missing.

---

## Phase 7 — Commit, Push & Hand Off

```bash
cd "${WORKTREE}"
git add -A && git commit -m "{{ARGUMENTS}}: feat: [short description]

- [changes]
Fixes {{ARGUMENTS}}"
git push -u origin "${BRANCH}"
```

Update status:
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <review_pending_uuid>
```

Post completion comment with: **Branch name** (required — reviewer reads this), files changed, test summary, inline screenshots `![alt]($ASSET_URL)`, API JSON blocks, "Next step: `/ticket-review {{ARGUMENTS}}`".

Worktree stays — do not remove.

---

## Status Transitions

```
Backlog / Todo  →  In Progress      (Phase 0)
In Progress     →  Review Pending   (Phase 7)
In Progress     →  Done             (Phase 7, self-contained)
```

## Critical Rules

1. Claim first — In Progress before any file operation
2. All paths use `$WORKTREE` — never touch the main repo
3. Never work on `develop` directly
4. Push before handing off — reviewer needs branch on origin
5. Record branch name in completion comment
6. Do not remove worktree — persists for review
7. Visual proof mandatory — Phase 6 cannot be skipped
8. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
