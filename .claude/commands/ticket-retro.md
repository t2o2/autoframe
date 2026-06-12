---
description: Run a retrospective on a human-approved ticket — inspect the branch, reconstruct the journey, extract learnings, persist reusable lessons to the repo, post findings as a comment, and hand off to merge
runInPlanMode: false
scope: project
---

Retrospective for a Linear ticket: while the branch is still live, inspect the actual diff and commit history, reconstruct the full journey from research through human review, extract process learnings, post a structured retro comment, write the per-ticket artifact, **distil any novel reusable lesson into the curated `thoughts/retrospectives/LESSONS.md`, and commit those docs to the ticket branch** (they ride to develop via the merge stage), then move `Retrospective → Merge` to hand off to the merge stage. All Linear API via `~/.agents/skills/linear/` scripts. No product/source-code changes and no merges — the only writes are the retrospective docs under `thoughts/retrospectives/`.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Inputs — Artifacts First

Prior stages hand off through `thoughts/tickets/{{ARGUMENTS}}/`, not the Linear thread. Read the artifact(s) below first; treat the comment thread as a fallback you pull **on demand** — only for data the artifacts and git don't carry (here: cycle counts and timestamps).

- **Primary input (this stage):** git `log`/`diff` (the actual change) + `research.md`, `plan.md`, `implementation.md`, `review.md` (the journey substance).
- **Metadata fetch (no thread):** `bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'`
- **Thread on demand (timeline & cycle counts — Phase 2b):** `bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq -r '.comments.nodes[] | "[\(.createdAt)] \(.user.name): \(.body)"'`

Unlike other stages, retro *does* need the thread — but for cycle/timestamp data only. Pull substance (what was found, planned, reviewed) from the artifacts; pull the thread for the audit timeline.

---

## Phase 1 — Fetch & Claim

Fetch metadata (no thread) in parallel:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'
bash ~/.agents/skills/linear/list-states.sh
```

Parse: title, description, priority, labels. Read `research.md`, `plan.md`, `implementation.md`, `review.md` for the journey substance; the full comment thread is pulled in Phase 2b for the audit timeline (cycle counts, timestamps).

Claim:
```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <ready_for_retrospective_uuid>
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

Now pull the thread on demand (see Inputs block) and reconstruct the timeline. Prefer the artifacts for *what happened*; use the thread for *when* and *how many cycles*:

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

### 4b — Write the per-ticket artifact (into the worktree)

All retro doc writes go **inside `${WORKTREE}`** so they ride the branch to develop via the merge stage. `${WORKTREE}` was resolved in Phase 2a.

```bash
mkdir -p "${WORKTREE}/thoughts/retrospectives"
```

Write the retrospective to `${WORKTREE}/thoughts/retrospectives/{{ARGUMENTS}}.md` with the full content from 4a.

Also append a one-line entry to `${WORKTREE}/thoughts/retrospectives/index.md` (create if absent):
```
- {{ARGUMENTS}}: [title] — [date] — [N changes-required cycles] — [key learning in one sentence]
```

### 4c — Distil reusable lessons into the curated LESSONS.md

This is the step that makes lessons persist and compound — `LESSONS.md` is read at the start of the research, plan, and process stages. Persist only what generalises **beyond this ticket**.

Read the existing log first so you don't duplicate:
```bash
LESSONS="${WORKTREE}/thoughts/retrospectives/LESSONS.md"
cat "${LESSONS}" 2>/dev/null
```

From the 3–6 learnings in Phase 3, keep only those that are **novel** (not already present anywhere in `LESSONS.md`) **and reusable** by future tickets of similar type. Drop anything that is ticket-specific trivia or merely reinforces an existing lesson.

If at least one novel reusable lesson remains, **append** a single block to the end of the `## Retrospective Log` section (after the `<!-- New blocks are appended below this line -->` marker):
```markdown

### {{ARGUMENTS}} — [date] — [short title]
- **[lesson title]**: [reusable, actionable guidance for similar future tickets]
- …
```

Rules — these keep the file auto-mergeable across parallel branches:
- **Append only.** Never edit or delete existing blocks, and never rewrite the `## Standing Lessons` section (that section is human-curated).
- 1–4 bullets max per block; each must be reusable guidance, not a ticket-specific note.
- **If no novel reusable lesson exists, make no change to `LESSONS.md`.** Empty-diff commits are noise.

### 4d — Commit the retrospective docs to the ticket branch

```bash
git -C "${WORKTREE}" add thoughts/retrospectives/
if git -C "${WORKTREE}" diff --cached --quiet; then
  echo "No retro doc changes to commit"
else
  git -C "${WORKTREE}" commit -m "{{ARGUMENTS}}: docs: retrospective + lessons learnt"
fi
```

This commit advances the local `${BRANCH}` ref; the merge stage's `merge --ff-only` (or union-resolved `--no-ff`) carries it to develop. **Do not push** — the merge stage owns the remote. **Do not `git add` anything outside `thoughts/retrospectives/`.**

---

## Phase 5 — Transition to Merge

```bash
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <ready_for_merge_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Retrospective complete ✅ — findings posted above. Handing off to merge."
```

---

## Status Transitions

```
Retrospective  →  Merge   (Phase 5)
```

## Critical Rules

1. Claim before working — set Retrospective status first
2. Artifacts + git first for substance; pull the Linear thread on demand for timeline/cycle data only (metadata fetch uses `jq 'del(.comments)'`)
3. No product/source-code changes and no merges. The **only** writes are the retro docs under `${WORKTREE}/thoughts/retrospectives/` (per-ticket artifact, index, and the curated `LESSONS.md`), committed to the ticket branch. `git diff`/`git log` for inspection is allowed.
4. `LESSONS.md` is **append-only**: only add a new ticket-tagged block to the Retrospective Log, and only when the lesson is novel and reusable. Never edit existing blocks or the Standing Lessons section — this is what lets the merge stage auto-resolve concurrent appends.
5. Base all findings on the actual branch diff + comment history — do not invent or speculate
6. Post retro comment before writing the artifact/LESSONS files
7. Commit the docs to the branch (Phase 4d), but **never push** — the merge stage owns the remote
8. Move to Merge last — only after comment + docs are committed
9. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
10. All doc writes go under `${WORKTREE}/thoughts/retrospectives/` — create the dir if absent; never write to the main repo working tree
11. Never remove the worktree — it is owned by the merge stage
