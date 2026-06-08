# Lessons Learnt

Persistent, cross-ticket engineering and process lessons distilled by the autonomous
pipeline's retrospective stage (`/ticket-retro`). This file is read at the start of the
research, plan, and process stages so each new ticket benefits from what earlier tickets
taught — lessons compound here instead of evaporating into per-ticket Linear comments.

## How this file is maintained

- **Retrospective Log (bottom)** — append-only. Each `/ticket-retro` run appends one
  ticket-tagged block at end-of-file, and only when there is a *novel, reusable* lesson.
  Never edit or delete prior blocks: keeping the region purely additive is what lets
  `git merge` auto-resolve two branches that both appended (see the union-merge rule in
  `.claude/commands/ticket-approve.md`).
- **Standing Lessons (top)** — human-curated. Promote a recurring lesson here once it has
  shown up across several tickets. The autonomous agent *reads* this section but does not
  rewrite it — automated rewrites would reintroduce merge conflicts in the parallel
  worktree pipeline.
- Retro appends a block only when a lesson is not already captured. A ticket that merely
  reinforces an existing lesson adds nothing here; promoting/annotating it is the human
  curator's job.

---

## Standing Lessons

_Human-curated. Recurring lessons promoted from the log below. Format:_
`- **<lesson>** — <why / how to apply> (seen: TICKET-1, TICKET-2)`

_None yet._

---

## Retrospective Log

_Append-only, newest at the bottom. One block per `/ticket-retro` run. Format:_

```
### TICKET-123 — YYYY-MM-DD — short title
- **<lesson title>**: reusable, actionable guidance for similar future tickets
```

<!-- New blocks are appended below this line. Do not edit existing blocks. -->
