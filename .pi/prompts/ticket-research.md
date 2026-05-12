---
description: Research a Linear ticket — explore the codebase and post findings as a ticket comment, then move to Research Pending Approval
argument-hint: "<ticket-id>"
---

Research a ticket: explore codebase, post structured findings, move `Todo → Research → Research Pending Approval`. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: $ARGUMENTS

---

## Phase 1 — Fetch & Claim

Fetch in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "$ARGUMENTS"
bash ~/.agents/skills/linear/list-states.sh
```

Parse: title, description, priority, labels, team ID. Comments in `.comments.nodes`.

Claim:
```bash
bash ~/.agents/skills/linear/update-issue.sh "$ARGUMENTS" --state-id <research_uuid>
bash ~/.agents/skills/linear/add-comment.sh "$ARGUMENTS" "Picking up research for $ARGUMENTS."
```

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

1. Post research:
   ```bash
   bash ~/.agents/skills/linear/add-comment.sh "$ARGUMENTS" "[research markdown]"
   ```

2. Transition:
   ```bash
   bash ~/.agents/skills/linear/update-issue.sh "$ARGUMENTS" --state-id <research_pending_approval_uuid>
   bash ~/.agents/skills/linear/add-comment.sh "$ARGUMENTS" "Research complete. Move to **Research Approved** to trigger planning."
   ```

3. Write artifact to `thoughts/tickets/$ARGUMENTS/research.md`

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
7. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
