---
description: Rebase an approved ticket branch onto the main branch (or parent ticket's branch), fast-forward merge, push to remote, and clean up the worktree and branch
argument-hint: "<ticket-id>"
---

Rebase ticket branch onto target, fast-forward merge, push, clean up. Uses rebase+ff-only to avoid silently overwriting concurrent changes. If ticket has a parent, rebase onto parent's branch instead of main.

## Request

Ticket ID: $ARGUMENTS

---

## Phase 0 — Resolve Branch & Worktree

```bash
TICKET="$ARGUMENTS"
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

Fetch ticket via `linear_gql`. If `parentId` exists → fetch parent → resolve parent branch. No parent branch → fall back to main. No parent → `TARGET_BRANCH="${GIT_BASE_BRANCH:-develop}"`.

---

## Phase 1 — Pre-Rebase Safety

```bash
git fetch origin "${BRANCH}" "${TARGET_BRANCH}"
git checkout "${TARGET_BRANCH}" && git pull origin "${TARGET_BRANCH}"
git log ${TARGET_BRANCH}..${BRANCH} --oneline
git diff ${TARGET_BRANCH}...${BRANCH} --stat
```

---

## Phase 2 — Rebase & Fast-Forward

```bash
git checkout "${BRANCH}" && git rebase "${TARGET_BRANCH}"
```
Fails → `git rebase --abort`, report, exit.

```bash
git checkout "${TARGET_BRANCH}" && git merge --ff-only "${BRANCH}"
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

Move to Done via `linear_gql` `issueUpdate`. Post comment: "Approved & Merged ✅ — `${BRANCH}` → `${TARGET_BRANCH}`. Cleaned up."

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
✅ /ticket-approve $ARGUMENTS complete
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

1. Always fetch before rebasing
2. Rebase aborts on conflict — `git rebase --abort`, never force-resolve
3. Rebase then ff-only — guarantees commits on latest state
4. Push before cleanup — verify on origin first
5. Delete both local and remote branches
6. Move to Done last — only after push verified
7. Never force-push protected branches
