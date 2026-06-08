---
description: Create a phased implementation plan for a Linear ticket and post it as a comment, then move to Plan Pending Approval
runInPlanMode: false
scope: project
---

Create a phased implementation plan: read research, explore gaps, design phases with file changes + success criteria, post to Linear. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 1 — Fetch Ticket & Research

Fetch in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}"
bash ~/.agents/skills/linear/list-states.sh
```

Check research artifact first:
```bash
RESEARCH_ARTIFACT="thoughts/tickets/{{ARGUMENTS}}/research.md"
[ -f "$RESEARCH_ARTIFACT" ] && echo "Reading research artifact" || echo "Scanning Linear comments for research"
```

Also read the cross-ticket lessons log and apply relevant prior learnings to the plan's approach, phasing, and risks:
```bash
cat thoughts/retrospectives/LESSONS.md 2>/dev/null
```

Extract: title, description, priority, labels, team ID, research findings (relevant files, patterns, complexity, decisions).

Claim:
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <planning_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Starting implementation planning for {{ARGUMENTS}}."
```

---

## Phase 2 — Fill Research Gaps

Spawn focused `Explore` agents only for genuine gaps. Prefix every sub-agent prompt with: `"MUST NOT suggest/critique/recommend. ONLY DO: <specific task>. Return file:line refs only."`

Examples: interface definitions, dependency maps, test patterns, migration conventions.

Spawn in parallel. Wait for all. If research was thorough, may need 0–2 agents.

---

## Phase 3 — Resolve Key Decisions

Identify architectural decisions. If genuinely ambiguous and needs human input:
```bash
./scripts/ask-human.sh {{ARGUMENTS}} "<question>" "<option1>" "<option2>"
```
Timeout → default to option 1. No credentials → post comment, proceed conservatively.

---

## Phase 4 — Write the Implementation Plan

Phased plan — each phase independently testable. Structure:

```markdown
## Implementation Plan: {{ARGUMENTS}} — [Title]

### Overview
[2–3 sentences: approach + rationale]

### What We're NOT Doing
[Explicit scope boundaries]

### Phase N — [Name]
**Goal:** [one sentence]
**Files:** path → change description
**Success criteria:** automated checks + manual verification

### Testing Strategy
Unit tests to add, integration tests, regression risks.

### Rollback Notes
[How to undo]
```

---

## Phase 5 — Post Plan & Transition

1. Post plan as comment:
   ```bash
   bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "[plan markdown]"
   ```

2. Move to Plan Pending Approval:
   ```bash
   bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <plan_pending_approval_uuid>
   bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Plan posted. Move to **Plan Approved** to trigger coding agent."
   ```

3. Write artifact to `thoughts/tickets/{{ARGUMENTS}}/plan.md` with: overview, scope boundaries, phase checklist, key files, testing strategy.

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
7. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
