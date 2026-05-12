---
description: Research a Linear ticket — explore the codebase and post findings as a ticket comment, then move to Research Pending Approval
argument-hint: "<ticket-id>"
---

Research a ticket: explore codebase, post structured findings, move `Todo → Research → Research Pending Approval`.

## Request

Ticket ID: $ARGUMENTS

---

## Phase 1 — Fetch & Claim

Fetch via `linear_gql` (bash+curl): issue details, workflow states, comments — in parallel.

Parse: title, description, priority, labels, team ID.

Claim:
```
linear_gql issueUpdate → { statusId: <research_id> }
```
Post: "Picking up research for $ARGUMENTS."

Vague description (< 2 actionable sentences) → `./scripts/ask-human.sh` or `ask_user_question`.

---

## Phase 2 — Identify Research Areas

Decompose ticket: affected services/components, relevant patterns, data models/interfaces, related tickets, risk areas.

---

## Phase 3 — Parallel Codebase Exploration

Spawn `Explore` agents in parallel. Prefix every prompt with: `"MUST NOT suggest/critique/recommend. ONLY DO: <task>. Return file:line refs only."`

Adapt to ticket. Common agents: scope, patterns, tests, schema/types.

Wait for **ALL** before Phase 4.

---

## Phase 4 — Synthesize Research

Compile into structured document:

```markdown
## Research: $ARGUMENTS — [Title]

### Summary
[2–4 sentences: scope, findings, complexity]

### Relevant Files
| File | What it does | Relevance |

### Current Implementation
[How it works today — file:line refs]

### Patterns to Follow
[Examples to mirror — file:line refs]

### Existing Tests
[Coverage — file paths + behaviors]

### Complexity Assessment
Scope: [trivial/small/medium/large] | Risks: [...] | Blockers: [...]

### Key Decisions for the Planner
[Ambiguities, or "none"]
```

---

## Phase 5 — Post Research & Transition

1. Post research via `linear_gql` `commentCreate`
2. Move to Research Pending Approval via `issueUpdate`
3. Post: "Research complete. Move to **Research Approved** to trigger planning."
4. Write artifact to `thoughts/tickets/$ARGUMENTS/research.md`

---

## Status Transitions

```
Todo       →  Research                    (Phase 1)
Research   →  Research Pending Approval   (Phase 5)
```

## Critical Rules

1. Claim before exploring — set Research status first
2. Document what IS — never suggest changes; read-only
3. Concrete file:line references for every finding
4. Post to Linear — research lives as ticket comment
5. No code changes
6. Wait for all sub-agents before synthesizing
