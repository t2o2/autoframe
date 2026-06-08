---
description: Research a Linear ticket — explore the codebase and post findings as a ticket comment, then move to Research Pending Approval
runInPlanMode: false
scope: project
---

Research a Linear ticket: explore codebase, post structured findings as comment, move `Todo → Research → Research Pending Approval`. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Inputs — Artifacts First

Prior stages hand off through `thoughts/tickets/{{ARGUMENTS}}/`, not the Linear thread. Read the artifact(s) below first; treat the comment thread as a fallback you pull **on demand** — only when an artifact is missing, or for data only the thread carries (human replies, timestamps, branch name).

- **Primary input (this stage):** none — research is the entry point. The ticket **description** is the source of truth; pull the thread once only if it carries human-provided context.
- **Metadata fetch (no thread):** `bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'`
- **Thread on demand:** `bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq -r '.comments.nodes[] | "[\(.createdAt)] \(.user.name): \(.body)"'`

`get-issue.sh` always embeds the full comment thread; the `del(.comments)` projection strips it inside the subprocess, keeping it out of context until you deliberately pull it.

---

## Phase 1 — Fetch & Claim

Fetch metadata (no thread) in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'
bash ~/.agents/skills/linear/list-states.sh
```

Parse: title, description, priority, labels, team ID. If the description references prior discussion, pull human comments once via the on-demand thread command above.

Claim:
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <research_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Picking up research for {{ARGUMENTS}}."
```

If too vague (< 2 actionable sentences): `./scripts/ask-human.sh {{ARGUMENTS}} "<question>" [options...]` — it @-mentions the ticket owner on Linear and waits. Use `AskUserQuestion` only in an attended/interactive session.

---

## Phase 2 — Identify Research Areas

First, read the cross-ticket lessons log so prior retrospectives shape this research:
```bash
cat thoughts/retrospectives/LESSONS.md 2>/dev/null
```
Factor any relevant Standing Lessons and recent log entries into the research areas and risk flags below.

Decompose ticket into research areas: affected services/components, relevant patterns, data models/interfaces, related tickets, risk areas.

---

## Phase 3 — Parallel Codebase Exploration

Spawn `Explore` agents in parallel. Prefix every sub-agent prompt with: `"MUST NOT suggest/critique/recommend. ONLY DO: <specific task>. Return file:line refs only."`

Adapt to ticket needs. Common agents: scope (find files), patterns (find similar code), tests (find existing tests), schema/types (find definitions).

Wait for **ALL** before Phase 4.

---

## Phase 4 — Synthesize Research

Compile findings into structured document:

```markdown
## Research: {{ARGUMENTS}} — [Title]

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
[Ambiguities requiring design choice, or "none"]
```

---

## Phase 5 — Post Research & Transition

1. Post research document:
   ```bash
   bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "[research markdown]"
   ```

2. Transition:
   ```bash
   bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <research_pending_approval_uuid>
   bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Research complete. Move to **Research Approved** to trigger planning."
   ```

3. Write artifact to `thoughts/tickets/{{ARGUMENTS}}/research.md` with: summary, relevant files, patterns, key decisions.

---

## Status Transitions

```
Todo       →  Research                    (Phase 1)
Research   →  Research Pending Approval   (Phase 5)
```

## Critical Rules

1. Claim before exploring — set Research status first
2. Artifacts first; pull the Linear thread only on demand — metadata fetch uses `jq 'del(.comments)'`
3. Document what IS — never suggest changes; read-only
4. Concrete file:line references for every finding
5. Post to Linear — research lives as ticket comment
6. No code changes
7. Wait for all sub-agents before synthesizing
8. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
