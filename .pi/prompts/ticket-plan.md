---
description: Create a phased implementation plan for a Linear ticket and post it as a comment, then move to Plan Pending Approval
argument-hint: "<ticket-id>"
---

Create phased implementation plan: read research, explore gaps, design phases with file changes + success criteria, post to Linear.

## Request

Ticket ID: $ARGUMENTS

---

## Phase 1 — Fetch Ticket & Research

Fetch via `linear_gql` (bash+curl): issue details, workflow states, comments — in parallel.

Check research artifact first:
```bash
RESEARCH_ARTIFACT="thoughts/tickets/$ARGUMENTS/research.md"
[ -f "$RESEARCH_ARTIFACT" ] && echo "Reading research artifact" || echo "Scanning comments"
```

Extract: title, description, priority, labels, research findings.

Claim:
```
linear_gql issueUpdate → { statusId: <planning_id> }
```
Post: "Starting planning for $ARGUMENTS."

---

## Phase 2 — Fill Research Gaps

Spawn focused `Explore` agents for genuine gaps only. Prefix every prompt with: `"MUST NOT suggest/critique/recommend. ONLY DO: <task>. Return file:line refs only."`

Examples: interface definitions, dependency maps, test patterns, migration conventions.

Parallel. Wait for all. May need 0–2 agents if research was thorough.

---

## Phase 3 — Resolve Key Decisions

Identify architectural decisions. If human judgment needed:
```bash
./scripts/ask-human.sh $ARGUMENTS "<question>" "<option1>" "<option2>"
```
Timeout → default. No credentials → post comment, proceed conservatively.

---

## Phase 4 — Write the Implementation Plan

Phased plan — each phase independently testable:

```markdown
## Implementation Plan: $ARGUMENTS — [Title]

### Overview
[2–3 sentences: approach + rationale]

### What We're NOT Doing
[Scope boundaries]

### Phase N — [Name]
**Goal:** [one sentence]
**Files:** path → change description
**Success criteria:** automated checks + manual verification

### Testing Strategy
Unit tests, integration tests, regression risks.

### Rollback Notes
### References
```

---

## Phase 5 — Post Plan & Transition

1. Post plan as comment via `linear_gql` `commentCreate`
2. Move to Plan Pending Approval via `issueUpdate`
3. Post: "Plan posted. Move to **Plan Approved** to trigger coding agent."
4. Write artifact to `thoughts/tickets/$ARGUMENTS/plan.md`

---

## Status Transitions

```
Research Approved  →  Planning              (Phase 1)
Planning           →  Plan Pending Approval (Phase 5)
```

## Critical Rules

1. Read research first — extract all prior findings before exploring
2. Phases must be independently testable
3. Concrete file references — every change names the exact path
4. No implementation — plan only, zero code changes
5. Post to Linear — plan lives as a ticket comment
6. Explicit scope boundary — always include "What We're NOT Doing"
