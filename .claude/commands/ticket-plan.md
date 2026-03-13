---
description: Create a phased implementation plan for a Linear ticket and post it as a comment, then move to Pending Plan Approval
runInPlanMode: false
scope: project
---

Create a detailed implementation plan for a Linear ticket. Reads the ticket's research comment, explores any gaps in the codebase, designs a phased plan with specific file changes and success criteria, and posts it as a ticket comment. Moves the ticket to `Pending Plan Approval`.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 1 — Fetch Ticket & Research

Fetch everything in parallel:

1. `mcp__linear-server__get_issue` — full ticket details
2. `mcp__linear-server__list_issue_statuses` — valid status IDs for the team
3. `mcp__linear-server__list_comments` — find the research comment from the research agent

Parse and record:

- Title, description, priority, labels, team ID
- **Research comment** — find the comment containing `## Research: {{ARGUMENTS}}` (posted by the research agent)
- Extract from research: relevant files, patterns to follow, complexity estimate, key decisions

If no research comment exists, treat the ticket description as the only input — do not block, but note the absence in the plan.

Set ticket status to `Planning` (claim it before exploring):

```
mcp__linear-server__save_issue → { id, statusId: <planning_id> }
```

Post a claiming comment:
> "Starting implementation planning for {{ARGUMENTS}}. Reading research findings and exploring codebase to produce a phased plan."

---

## Phase 2 — Fill Research Gaps

Using the research findings as the starting point, identify what still needs deeper investigation to write a concrete plan (e.g., exact function signatures, interface shapes, migration patterns).

Spawn focused `Explore` agents for any gaps — only what is genuinely needed. Examples:

- **Interface agent** — "Show me the exact types for [interface/struct]. Return the definition with file:line."
- **Dependency agent** — "What does [component X] depend on? List imports and trait implementations."
- **Test pattern agent** — "Show me how tests are structured for [component]. What setup helpers exist?"
- **Migration agent** — "Find existing SQL migrations in this repo. Show the naming convention and a representative example."

Spawn agents in parallel. Wait for **ALL** before proceeding.

If research was thorough, this phase may require only 1–2 agents or none at all.

---

## Phase 3 — Resolve Key Decisions

Before writing the plan, identify any architectural decisions that must be made:

- Does the ticket fit cleanly into existing patterns, or does it require a new approach?
- Are there multiple valid implementations — if so, which is most consistent with the codebase?
- Does any part of the ticket scope conflict with the current architecture?

If a decision genuinely requires human judgment and cannot be resolved by reading the code, ask via Telegram then proceed with the response:

```
Bash: ./scripts/ask-human.sh {{ARGUMENTS}} "<question>" "<option1>" "<option2>" "<option3>"
```

Use the returned text as the chosen approach. If the script exits 1 (timeout), the default (option 1) was applied — note this in the plan. If the script exits 2 (no credentials), fall back to posting a Linear comment and proceeding with the most conservative approach:
> "Planning for {{ARGUMENTS}}: key decision — [question]. Proceeding with [chosen approach] — override by moving ticket back to Planning with a comment."

---

## Phase 4 — Write the Implementation Plan

Write a phased plan where each phase is independently testable and deployable. Keep phases small.

```markdown
## Implementation Plan: {{ARGUMENTS}} — [Ticket Title]

**Ticket:** [title]
**Type:** [bug / feature / improvement / chore]
**Planned:** [ISO date]
**Estimated scope:** [trivial / small / medium / large]
**Research:** [link to research comment, or "none — working from ticket description"]

### Overview
[2–3 sentences: what we're building, the approach chosen, and why it fits the codebase]

### What We're NOT Doing
[Explicit scope boundaries — prevents implementation drift]
- [out-of-scope item]
- [out-of-scope item]

---

### Phase 1 — [Descriptive name, e.g., "Database migration"]

**Goal:** [what this phase achieves in one sentence]

**Files to change:**

| File | Change description |
|------|--------------------|
| `path/to/file.rs` | [what to add/modify and why] |
| `migrations/YYYYMMDD_name.sql` | [schema change] |

**Implementation notes:**
[Specific guidance: function signatures to add, trait implementations needed, patterns to follow. Include file:line refs to examples.]

**Success criteria:**

Automated:
- [ ] `cargo test --all` passes
- [ ] `cargo clippy --all-targets --all-features` clean
- [ ] [specific test or curl command for this phase's change]

Manual:
- [ ] [observable behaviour to verify in the UI or via API]

---

### Phase 2 — [Descriptive name, e.g., "Service layer"]

[Same structure as Phase 1]

---

### Phase N — [Descriptive name, e.g., "Frontend integration"]

[Same structure]

---

### Testing Strategy

**Unit tests to add:**
- `path/to/tests.rs` — [behaviour to test, including edge cases]

**Integration tests:**
- [scenario description and how to trigger it]

**Regression risk:**
- [component that could regress, and how to verify it didn't]

### Rollback Notes
[How to undo if something goes wrong — SQL rollback, feature flag, revert commit]

### References
- Ticket: {{ARGUMENTS}}
- Research comment: [description of where to find it]
- Similar implementation: `path/to/similar.rs:42`
```

---

## Phase 5 — Post Plan & Transition

1. Post the full implementation plan as a ticket comment:

   `mcp__linear-server__save_comment` → `{ issue: "{{ARGUMENTS}}", body: <plan> }`

2. Set ticket status to `Pending Plan Approval`:

   `mcp__linear-server__save_issue` → `{ id, statusId: <pending_plan_approval_id> }`

3. Post a final summary comment:
   > "Implementation plan posted above. **Next step:** review the plan and move ticket to **Plan Approved** to trigger the coding agent (`/ticket-process`)."

---

## Status Transitions

```
Research Approved  →  Planning              (Phase 1 — claim)
Planning           →  Pending Plan Approval (Phase 5)
```

## Critical Rules

1. **Read research first** — extract all prior findings before any codebase exploration
2. **Phases must be independently testable** — each phase has its own success criteria
3. **Concrete file references** — every planned change must name the exact file path
4. **No implementation** — this command produces a plan only; zero code changes are made
5. **Post to Linear** — the plan lives as a ticket comment, not just local context
6. **Explicit scope boundary** — always include a "What We're NOT Doing" section

## Orchestration Map

```
/ticket-plan GYL-XX
        │
        ▼
Phase 1: Fetch Ticket & Research
  get_issue + list_issue_statuses + list_comments  [parallel]
  save_issue: Planning  ← claim step
  extract research comment
  save_comment: "starting planning"
        │
        ├── no research? → note absence, continue from description
        │
        ▼
Phase 2: Fill Research Gaps  [parallel Explore agents as needed]
  ┌─────────────────────┐ ┌─────────────────────────┐
  │  Explore (types)    │ │  Explore (test patterns) │
  └──────────┬──────────┘ └──────────┬───────────────┘
             └───────────┬───────────┘
                         ▼ (wait for all)
Phase 3: Resolve Key Decisions
  identify approach → post comment if human judgment needed
                         │
                         ▼
Phase 4: Write Implementation Plan
  phased plan → file changes → success criteria per phase
                         │
                         ▼
Phase 5: Post & Transition
  save_comment: implementation plan
  save_issue: Pending Plan Approval
  save_comment: "next step: move to Plan Approved"
```
