---
description: Run a retrospective on a human-approved ticket — inspect the branch, reconstruct the journey, extract learnings, post findings as a comment, and hand off to merge
runInPlanMode: false
scope: project
---

Retrospective for a Linear ticket: while the branch is still live, inspect the actual diff and commit history, reconstruct the full journey from research through human review, extract process learnings, post a structured retro comment, append to the repo retrospective log, and move `Retrospective → Merging` to hand off to the approve stage. All Linear API via `~/.agents/skills/linear/` scripts. Read-only — no code changes, no merges.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 1 — Fetch & Claim

Fetch in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}"
bash ~/.agents/skills/linear/list-states.sh
```

Parse: title, description, priority, labels, comments (all of `.comments.nodes` — these carry the full audit trail from research through merge).

Claim:
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <retrospective_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Running retrospective for {{ARGUMENTS}}."
```

---

## Phase 2 — Inspect Branch & Reconstruct the Journey

### 2a — Branch inspection (read-only git)

Locate the branch from comments (`.comments.nodes[].body`): match `**Branch:** \`feat/{{ARGUMENTS}}\`` or `fix/`. Fallback: `git branch -r | grep {{ARGUMENTS}}`.

```bash
TICKET="{{ARGUMENTS}}"
BRANCH="feat/${TICKET}"   # or fix/ from comment
WORKTREE="../worktrees/${BRANCH}"

# Diff summary — what actually changed
git -C "${WORKTREE}" diff develop...HEAD --stat 2>/dev/null || \
  git -C "${WORKTREE}" diff origin/develop...HEAD --stat 2>/dev/null

# Commit log — full history on the branch
git -C "${WORKTREE}" log develop..HEAD --oneline 2>/dev/null || \
  git -C "${WORKTREE}" log origin/develop..HEAD --oneline 2>/dev/null

# Files changed
git -C "${WORKTREE}" diff develop...HEAD --name-only 2>/dev/null
```

Record: total files changed, lines added/removed, number of commits, commit message quality.

### 2b — Comment history

Read the full comment history and reconstruct the timeline:

- **Research phase**: what was found, complexity estimate, key decisions flagged
- **Plan phase**: what approach was chosen, how closely the plan matched reality
- **Process phase**: how many `Changes Required` cycles occurred, why each one triggered
- **Review phase**: what issues were found, whether tests passed first time
- **Human review**: what the human saw before approving

Count:
- Total `Changes Required` cycles
- Total `Build Fail` events
- Total agent stale-reverts (if visible in comments)
- Total commits on branch (from 2a)
- Time from `Todo` → `Retrospective` (estimate from comment timestamps)

---

## Phase 3 — Extract Learnings

Analyse the journey for actionable process improvements. Consider:

- Were the research findings accurate and complete enough for planning?
- Did the plan anticipate the actual implementation complexity?
- What caused each `Changes Required` cycle — missing context, unclear acceptance criteria, code quality issues?
- Were there recurring patterns (e.g. always failing the build check, always needing one extra process cycle)?
- What would have shortened the ticket's cycle time the most?
- What worked well that should be preserved or standardised?

Produce 3–6 concise, actionable learnings. Each learning must be:
- Specific to this ticket (not generic advice)
- Tied to a concrete observation from the journey
- Expressed as a recommendation for future tickets of similar type

---

## Phase 4 — Post Retro & Write Artifact

### 4a — Post retro comment to Linear

```bash
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "[retro markdown — see template below]"
```

Retro comment template:
```markdown
## Retrospective: {{ARGUMENTS}} — [Title]

### Branch Summary
- **Files changed**: N (list key files)
- **Lines**: +X −Y
- **Commits**: N

### Journey Summary
| Stage | Cycles | Notes |
|-------|--------|-------|
| Research | 1 | … |
| Plan | 1 | … |
| Process | N | … (N-1 Changes Required cycles) |
| Review | N | … |
| Human Review | — | approved |

**Total cycle time**: [estimate]
**Changes Required cycles**: N
**Build failures**: N
**Total commits on branch**: N

### What Went Well
- …

### What Could Be Improved
- …

### Learnings
1. **[Short title]**: [specific, actionable recommendation]
2. …

### Process Improvement Suggestions
[1–3 suggestions for the pipeline itself — prompts, stage commands, acceptance criteria templates, etc.]
```

### 4b — Write artifact to repo

Write the retrospective to `thoughts/retrospectives/{{ARGUMENTS}}.md` with the full content from 4a.

Also append a one-line entry to `thoughts/retrospectives/index.md` (create if absent):
```
- {{ARGUMENTS}}: [title] — [date] — [N changes-required cycles] — [key learning in one sentence]
```

---

## Phase 5 — Transition to Merging

```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <merging_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Retrospective complete ✅ — findings posted above. Handing off to merge."
```

---

## Status Transitions

```
Retrospective  →  Merging   (Phase 5)
```

## Critical Rules

1. Claim before working — set Retrospective status first
2. Read-only — no code changes, no merges, no worktree removal; `git diff`/`git log` is allowed
3. Base all findings on the actual branch diff + comment history — do not invent or speculate
4. Post retro comment before writing the artifact file
5. Move to Merging last — only after comment + artifact are written
6. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
7. `thoughts/retrospectives/` directory must exist — create it if absent
8. Never remove the worktree — it is owned by the approve stage
