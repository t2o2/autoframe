---
description: Set up the environment for human review of a Linear ticket — checkout branch, start services, execute prerequisites, and present the final state for human judgement
runInPlanMode: false
scope: project
---

Prepare a fully running environment for a human to review a Linear ticket. By the end of this command the human should see the **exact outcome that needs judgement** — all mechanical setup and prerequisite actions completed automatically. The outcome may be a browser screen, an API response, a CLI output, or any other observable result.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Fetch Ticket & Find Branch

Fetch in parallel:

1. `mcp__linear-server__get_issue` — ticket title, description, acceptance criteria, labels, type
2. `mcp__linear-server__list_comments` — find the implementation branch posted by `/ticket-process`

Scan comments for a line matching `**Branch:** \`feat/{{ARGUMENTS}}\`` or `fix/{{ARGUMENTS}}`.

Fall back to git if not found in comments:

```bash
git fetch --all --prune
git branch -r | grep "{{ARGUMENTS}}"
```

If still no branch — stop:
> "No implementation branch found for {{ARGUMENTS}}. Run `/ticket-process {{ARGUMENTS}}` first."

Set variables:

```bash
TICKET="{{ARGUMENTS}}"
BRANCH="feat/${TICKET}"     # or fix/${TICKET}
WORKTREE="../worktrees/${BRANCH}"   # reuse the implementation worktree
```

**Extract and record:**

- `TICKET_TITLE` — the ticket title
- `ACCEPTANCE_CRITERIA` — list of acceptance criteria / Definition of Done items from the ticket description
- `TICKET_TYPE` — Bug Fix / Feature / Improvement

---

## Phase 1 — Locate Worktree

Reuse the existing implementation worktree. Do not create a new one.

```bash
git fetch origin "${BRANCH}"

if wtp ls 2>/dev/null | grep -q "${BRANCH}"; then
  echo "Reusing worktree for ${BRANCH}"
else
  # No impl worktree — create one (review without prior ticket-process)
  wtp add -b "${BRANCH}" 2>/dev/null || git worktree add "${WORKTREE}" "${BRANCH}"
fi

WORKTREE=$(wtp cd "${BRANCH}" 2>/dev/null || echo "../worktrees/${BRANCH}")
echo "Worktree: ${WORKTREE}"
```

Pull latest from origin into the worktree:

```bash
cd "${WORKTREE}" && git pull origin "${BRANCH}" --ff-only 2>/dev/null || true
```

---

## Phase 2 — Analyse What Changed & Classify Review Type

Collect the diff:

```bash
cd "${WORKTREE}"
git log develop..HEAD --oneline
git diff develop...HEAD --name-only
```

Classify changes — record which areas are touched:

- `frontend-issuance/` → **frontend changed**
- `keeper/` → **keeper changed**
- `starfish/` → **starfish changed**
- `gateway/` or `tokenization/` → **chainbooks/gateway changed**
- `migrations/` or `*.sql` → **database migration present**
- `contracts/` or `*.sol` → **contract changed**
- `docs/` or `*.md` → **documentation only**
- config files, CI, scripts → **infra/config changed**

**Determine the review type** based on acceptance criteria and changed files:

| Review Type | When | What to present |
|---|---|---|
| **UI** | Frontend files changed, criteria mention visual/interaction | Browser showing the relevant screen |
| **API** | Backend endpoints changed, criteria mention request/response | curl output showing the API response |
| **Backend logic** | Business logic changed, criteria mention behaviour/calculation | Test output or service logs showing the behaviour |
| **Config/infra** | Config, CI, deployment files changed | Relevant config state or command output |
| **Documentation** | Only docs changed | The rendered or raw docs for inspection |
| **Mixed** | Multiple areas — use the primary acceptance criterion to pick | The most representative proof for the primary criterion |

Launch an **Explore agent** (quick) scoped to changed files to produce:

- What changed, file-by-file (one sentence each)
- Which acceptance criteria each change satisfies
- What review type applies
- What **prerequisites** must be completed before the human can verify

---

## Phase 3 — Start Infrastructure

Only start infrastructure if the review type requires running services (UI, API, backend logic).

Skip for documentation-only or config-only changes.

```bash
# Check if postgres is up (simplest proxy for infra health)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q postgres; then
  echo "Infrastructure already running"
else
  echo "Starting infrastructure..."
  just dev &
  # Wait up to 60s for postgres
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q postgres && break
    sleep 2
  done
  echo "Infrastructure ready"
fi
```

If a database migration is present in the diff, run it now:

```bash
cd "${WORKTREE}" && just migrate 2>/dev/null || echo "No migrate target — run manually if needed"
```

---

## Phase 4 — Start Services

Start only the services needed for this review. Run each in background.

### Starfish (if starfish/ changed or needed for auth)

```bash
if ! curl -sf http://localhost:8101/health > /dev/null 2>&1; then
  echo "Starting Starfish..."
  cd "${WORKTREE}" && cargo build -p starfish --release 2>&1 | tail -5
  RUST_LOG=info ./target/release/starfish &
  for i in $(seq 1 30); do
    curl -sf http://localhost:8101/health > /dev/null 2>&1 && break
    sleep 2
  done
  echo "Starfish ready"
else
  echo "Starfish already running"
fi
```

### Keeper (if keeper/ changed or needed for staking/settlement)

```bash
if ! curl -sf http://localhost:8104/health > /dev/null 2>&1; then
  echo "Starting Keeper..."
  cd "${WORKTREE}/keeper" && npm run build 2>&1 | tail -5
  node dist/index.js &
  for i in $(seq 1 60); do
    curl -sf http://localhost:8104/health > /dev/null 2>&1 && break
    sleep 2
  done
  echo "Keeper ready"
else
  echo "Keeper already running"
fi
```

### Gateway / Chainbooks (if gateway/ changed)

```bash
if ! curl -sf http://localhost:8100/health > /dev/null 2>&1; then
  echo "Starting Gateway..."
  cd "${WORKTREE}" && cargo build -p gateway --release 2>&1 | tail -5
  RUST_LOG=info ./target/release/gateway &
  for i in $(seq 1 30); do
    curl -sf http://localhost:8100/health > /dev/null 2>&1 && break
    sleep 2
  done
fi
```

### Frontend (if frontend/ changed or UI review type)

```bash
if ! curl -sf http://localhost:8105 > /dev/null 2>&1; then
  echo "Starting frontend..."
  cd "${WORKTREE}/frontend-issuance"
  pnpm install --frozen-lockfile 2>&1 | tail -3
  pnpm dev &
  for i in $(seq 1 45); do
    curl -sf http://localhost:8105 > /dev/null 2>&1 && break
    sleep 2
  done
  echo "Frontend ready at http://localhost:8105"
else
  echo "Frontend already running — note: may be running develop, not ${BRANCH}"
fi
```

Record actual status:

```bash
echo "=== Service Health ==="
curl -sf http://localhost:8105 > /dev/null 2>&1 && echo "Frontend  :8105  UP" || echo "Frontend  :8105  DOWN"
curl -sf http://localhost:8101/health > /dev/null 2>&1 && echo "Starfish  :8101  UP" || echo "Starfish  :8101  DOWN"
curl -sf http://localhost:8104/health > /dev/null 2>&1 && echo "Keeper    :8104  UP" || echo "Keeper    :8104  DOWN"
curl -sf http://localhost:8100/health > /dev/null 2>&1 && echo "Gateway   :8100  UP" || echo "Gateway   :8100  DOWN"
```

---

## Phase 5 — Execute Prerequisites & Present Final State

This is the critical phase. The goal is to **automate all mechanical actions** so the human sees the exact outcome that needs their judgement.

### Step 1: Determine what the human needs to see

From the acceptance criteria and changed files, reason about:

1. **Final outcome** — what observable result proves the ticket works? (a screen, an API response, a log line, a test output, a file diff)
2. **Prerequisites** — what actions must happen first to produce that outcome?

**Think step by step:**

- What does the acceptance criterion describe?
- What state must exist for the outcome to be observable?
- What actions create that state? (browser clicks, API calls, CLI commands, data seeding)

### Step 2: Execute prerequisites

Use the appropriate tools based on what's needed. **Not every ticket needs a browser.** Choose the right tool for each prerequisite:

**Browser actions** (UI review type):

```
mcp__chrome-devtools__new_page
mcp__chrome-devtools__navigate_page → [url]
mcp__chrome-devtools__wait_for → [selector or text]
mcp__chrome-devtools__fill → [input selector], [value]
mcp__chrome-devtools__click → [button/link selector]
mcp__chrome-devtools__take_screenshot  → verify each step
```

Login (if browser is used):

```
mcp__chrome-devtools__navigate_page → http://localhost:8105
mcp__chrome-devtools__wait_for → selector: input[type="email"], timeout: 10000
mcp__chrome-devtools__fill → selector: input[type="email"], value: demo@gyld.io
mcp__chrome-devtools__fill → selector: input[type="password"], value: TestPassword123!
mcp__chrome-devtools__click → selector: button[type="submit"]
mcp__chrome-devtools__wait_for → url contains /dashboard OR selector: nav, timeout: 10000
```

**API calls** (API review type):

```bash
# Use curl to seed data or trigger actions
curl -X POST http://localhost:8104/[endpoint] -H 'Content-Type: application/json' -d '[body]'

# For authenticated endpoints, use demo credentials from CLAUDE.md
```

**CLI / service commands** (backend review type):

```bash
# Run commands, capture output, trigger processes
cd "${WORKTREE}" && [command]
```

**After each prerequisite action:**

- Verify it succeeded (check response, screenshot, or output)
- If an action fails, try once more; if it fails again, stop and report the failure

### Step 3: Present the final state

Based on the review type, present the outcome:

**UI review** — navigate to the target screen, interact to reveal the feature if needed (open modal, click dropdown, expand section), take a screenshot, leave the browser open:

```
mcp__chrome-devtools__navigate_page → [target page]
mcp__chrome-devtools__wait_for → [the element under review]
mcp__chrome-devtools__take_screenshot → /tmp/setup-review-{{ARGUMENTS}}-final.png
```

**API review** — make the API call and display the response:

```bash
curl -s [endpoint] | jq .
```

**Backend logic review** — run the relevant test or trigger the behaviour and show output:

```bash
cd "${WORKTREE}" && cargo test [specific_test] -- --nocapture
# or
cd "${WORKTREE}" && [command that demonstrates the behaviour]
```

**Documentation review** — display the changed content:

```bash
cd "${WORKTREE}" && git diff develop...HEAD -- [doc files]
```

**Config/infra review** — show the relevant state:

```bash
cd "${WORKTREE}" && [command showing config is correct]
```

---

## Phase 6 — Brief Handoff

Print a concise summary to the terminal. The human can see the result directly.

```
╔══════════════════════════════════════════════════════════════════════╗
║            READY FOR REVIEW — {{ARGUMENTS}}                         ║
╚══════════════════════════════════════════════════════════════════════╝

Ticket:   [ticket title]
Type:     [Bug Fix / Feature / Improvement]
Branch:   [branch name]
Worktree: [absolute worktree path]

What changed: [1–2 sentences — what is different]

Presenting: [description of what the human is looking at right now]
  e.g., "Browser open at /redeem showing the withdrawal address dropdown"
  e.g., "API response from POST /treasury/deposit showing new validation"
  e.g., "Test output showing the new calculation logic"

Prerequisites completed:
  [x] [e.g., Logged in as demo@gyld.io]
  [x] [e.g., Staked 5 SOL via UI]
  [x] [e.g., Triggered daily settlement — tokens minted]
  [x] [e.g., Navigated to /redeem — redemption form visible]

What to verify:
  - [acceptance criterion 1 — what to look for]
  - [acceptance criterion 2 — what to look for]

Services: [list only if services were started]
  Frontend  :8105  [UP/DOWN]
  Starfish  :8101  [UP/DOWN]
  Keeper    :8104  [UP/DOWN]

After review:
  Approve → /ticket-approve {{ARGUMENTS}}
  Reject  → move ticket to Changes Required in Linear
```

---

## Worktree Convention

| Attribute | Value |
|---|---|
| Branch | `feat/{{ARGUMENTS}}` or `fix/{{ARGUMENTS}}` |
| Worktree | `../worktrees/feat/{{ARGUMENTS}}` (shared — created by `/ticket-process`) |
| Lifecycle | Removed only by `/ticket-approve` |

## Critical Rules

1. **Reuse the impl worktree** — never create a new worktree; use `../worktrees/${BRANCH}`
2. **Actually start the services** — do not just describe how; run the commands and wait for health checks
3. **Start services from the worktree** — so the branch code is running, not develop
4. **Execute all prerequisites** — perform every mechanical action needed to produce the reviewable outcome
5. **Stop at the judgement point** — do not validate or judge; present the outcome and let the human decide
6. **Match the medium to the ticket** — use browser for UI tickets, curl for API tickets, test output for logic tickets. Not everything is a browser review.
7. **Never post to Linear** — this is for the human in the terminal only
8. **Keep services running** — do not stop anything when the command finishes
9. **Dynamic discovery** — infer prerequisites from acceptance criteria and codebase context, not from hardcoded flows

## Orchestration Map

```
/ticket-setup-review GYL-XX
        │
        ▼
Phase 0: Fetch ticket + find branch [parallel]
  get_issue + list_comments
  extract: title, acceptance criteria, type
        │
        ├── no branch? → tell human → exit
        │
        ▼
Phase 1: Locate impl worktree (reuse feat/GYL-XX)
  git pull origin feat/GYL-XX
        │
        ▼
Phase 2: Analyse changes + classify review type
  git diff --name-only + Explore agent
  → file summary, review type (UI / API / backend / docs / config)
  → prerequisites needed
        │
        ▼
Phase 3: Start infrastructure [if review type needs running services]
  just dev → wait for postgres
  run migration if SQL files changed
  skip for docs/config-only changes
        │
        ▼
Phase 4: Start services [only what's needed]
  starfish, keeper, gateway, frontend — based on review type + changed files
  health check each
        │
        ▼
Phase 5: Execute prerequisites + present final state
  5.1  reason: what outcome + what prerequisites?
       (from acceptance criteria + changed files + review type)
  5.2  execute prerequisites using appropriate tools:
       - browser automation (UI)
       - curl (API)
       - CLI commands (backend)
       - file reads (docs)
       verify each step succeeded
  5.3  present the final outcome:
       - browser on target screen (UI)
       - API response displayed (API)
       - test/command output (backend)
       - diff displayed (docs)
        │
        ▼
Phase 6: Brief handoff
  print: ticket summary + what's presented + what to verify
        │
        ▼
  Human reviews. When done:
    → /ticket-approve GYL-XX   (pass)
    → Move to Changes Required in Linear   (fail)
```
