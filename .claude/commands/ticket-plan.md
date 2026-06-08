---
description: Create a phased implementation plan for a Linear ticket and post it as a comment, then move to Plan Pending Approval
runInPlanMode: false
scope: project
---

Create a phased implementation plan: read research, explore gaps, design phases with file changes + success criteria, post to Linear. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Inputs — Artifacts First

Prior stages hand off through `thoughts/tickets/{{ARGUMENTS}}/`, not the Linear thread. Read the artifact(s) below first; treat the comment thread as a fallback you pull **on demand** — only when an artifact is missing, or for data only the thread carries (human replies, timestamps, branch name).

- **Primary input (this stage):** `research.md` — findings, relevant files, patterns, complexity, key decisions.
- **Metadata fetch (no thread):** `bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'`
- **Thread on demand (only if `research.md` is missing):** `bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq -r '.comments.nodes[] | "[\(.createdAt)] \(.user.name): \(.body)"'`

`get-issue.sh` always embeds the full comment thread; the `del(.comments)` projection strips it inside the subprocess, keeping it out of context until you deliberately pull it.

---

## Phase 1 — Fetch Ticket & Research

Read the research artifact first — it is the handoff from the research stage:
```bash
RESEARCH_ARTIFACT="thoughts/tickets/{{ARGUMENTS}}/research.md"
[ -f "$RESEARCH_ARTIFACT" ] && cat "$RESEARCH_ARTIFACT" || echo "No artifact — fall back to pulling the research comment on demand"
```

Fetch ticket metadata (no thread) in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'
bash ~/.agents/skills/linear/list-states.sh
```

Also read the cross-ticket lessons log and apply relevant prior learnings to the plan's approach, phasing, and risks:
```bash
cat thoughts/retrospectives/LESSONS.md 2>/dev/null
```

Extract: title, description, priority, labels, team ID (from metadata) + research findings (from `research.md`, or the on-demand thread pull if the artifact is absent).

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

1. Read `research.md` first — artifact is the handoff; pull the Linear thread only if it is missing (metadata fetch uses `jq 'del(.comments)'`)
2. Phases must be independently testable
3. Concrete file references — every change names the exact path
4. No implementation — plan only, zero code changes
5. Post to Linear — plan lives as a ticket comment
6. Explicit scope boundary — always include "What We're NOT Doing"
7. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
