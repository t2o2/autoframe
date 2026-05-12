---
description: Rebase an approved ticket branch onto the main branch (or parent ticket's branch), fast-forward merge, push to remote, and clean up the worktree and branch
runInPlanMode: false
scope: project
---

Rebase ticket branch onto target, fast-forward merge, push, clean up worktree + branch. Uses rebase+ff-only to avoid silently overwriting concurrent changes. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Resolve Branch & Worktree

```bash
TICKET="{{ARGUMENTS}}"
# Try feat/ then fix/, local then remote
if git show-ref --verify --quiet "refs/heads/feat/${TICKET}"; then
  BRANCH="feat/${TICKET}"
elif git show-ref --verify --quiet "refs/heads/fix/${TICKET}"; then
  BRANCH="fix/${TICKET}"
else
  BRANCH=$(git branch -r | grep -E "(feat|fix)/${TICKET}$" | head -1 | sed 's|origin/||' | tr -d ' ')
fi
[ -z "${BRANCH}" ] && echo "No branch found for ${TICKET}" && exit 1
WORKTREE="../worktrees/${BRANCH}"
```

---

## Phase 0.5 — Resolve Merge Target

Check for parent ticket in Linear:
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}"
```

If `parentId` exists → fetch parent → resolve parent's branch (`feat/` or `fix/`). If parent branch not found → fall back to main branch.

No parent → `TARGET_BRANCH="${GIT_BASE_BRANCH:-develop}"`.

---

## Phase 1 — Pre-Rebase Safety

```bash
git fetch origin "${BRANCH}" "${TARGET_BRANCH}"
git checkout "${TARGET_BRANCH}" && git pull origin "${TARGET_BRANCH}"
git log ${TARGET_BRANCH}..${BRANCH} --oneline   # audit trail
git diff ${TARGET_BRANCH}...${BRANCH} --stat
```

---

## Phase 2 — Rebase & Fast-Forward

```bash
git checkout "${BRANCH}"
git rebase "${TARGET_BRANCH}"
```
Rebase fails → `git rebase --abort`, report conflicts, exit.

```bash
git checkout "${TARGET_BRANCH}"
git merge --ff-only "${BRANCH}"
```

---

## Phase 3 — Push

```bash
git push origin "${TARGET_BRANCH}"
git fetch origin "${TARGET_BRANCH}"
[ "$(git rev-parse ${TARGET_BRANCH})" = "$(git rev-parse origin/${TARGET_BRANCH})" ] && echo "Verified"
```

---

## Phase 4 — Update Linear

```bash
bash ~/.agents/skills/linear/list-states.sh        # find "Done" UUID
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <done_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Approved & Merged ✅ — \`${BRANCH}\` → \`${TARGET_BRANCH}\`. Branch + worktree cleaned up."
```

---

## Phase 5 — Clean Up Worktree

```bash
wtp rm "${BRANCH}" 2>/dev/null || git worktree remove "${WORKTREE}" --force 2>/dev/null || true
git worktree prune
```

---

## Phase 6 — Delete Branch

```bash
git branch -D "${BRANCH}" 2>/dev/null || true
git push origin --delete "${BRANCH}" 2>/dev/null || true
git remote prune origin
```

---

## Phase 7 — Final Report

```
✅ /ticket-approve {{ARGUMENTS}} complete
  Rebased: ${BRANCH} → ${TARGET_BRANCH} (ff-only)
  Pushed: origin/${TARGET_BRANCH} (verified)
  Worktree: removed | Branch: deleted | Linear: Done
```

---

## Status Transitions

```
Human Review / In Review  →  Done  (after merge + push verified)
```

## Critical Rules

1. Always fetch before rebasing — never rebase onto stale branches
2. Rebase aborts on conflict — run `git rebase --abort`, never force-resolve
3. Rebase then ff-only — guarantees commits land on latest state
4. Push before cleanup — verify target on origin before deleting
5. Delete both local and remote branches
6. Move to Done last — only after push verified
7. Never force-push protected branches
8. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
