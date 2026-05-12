---
description: Merge an approved ticket branch onto the main branch (or parent ticket's branch), push to remote, and clean up the worktree and branch
argument-hint: "<ticket-id>"
---

Merge ticket branch onto target, push, clean up. Uses ff-only → no-ff fallback. If ticket has a parent, merge onto parent's branch instead of main. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: $ARGUMENTS

---

## Phase 0 — Identify Context

```bash
MAIN_REPO=$(git rev-parse --show-toplevel)
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

Check for parent ticket:
```bash
bash ~/.agents/skills/linear/get-issue.sh "$ARGUMENTS"
```

If `parentId` exists → fetch parent → resolve parent branch. No parent branch → fall back to main. No parent → `TARGET_BRANCH="${GIT_BASE_BRANCH:-develop}"`.

---

## Phase 1 — Pre-Merge

```bash
git fetch origin "${BRANCH}" "${TARGET_BRANCH}"
git -C "${MAIN_REPO}" checkout "${TARGET_BRANCH}"
git -C "${MAIN_REPO}" pull origin "${TARGET_BRANCH}"
git -C "${MAIN_REPO}" status --short   # must be clean
```
If not clean → stop, report, exit.

---

## Phase 2 — Merge

```bash
git -C "${MAIN_REPO}" merge --ff-only "${BRANCH}"
```
If `--ff-only` fails due to diverged histories:
```bash
git -C "${MAIN_REPO}" merge --no-ff "${BRANCH}" -m "Merge ${BRANCH} into ${TARGET_BRANCH}"
```
If `--ff-only` fails due to untracked files: check `git -C "${MAIN_REPO}" status --short`, remove conflicting files, retry.

---

## Phase 3 — Push

```bash
git -C "${MAIN_REPO}" push origin "${TARGET_BRANCH}"
```

---

## Phase 4 — Update Linear

```bash
bash ~/.agents/skills/linear/list-states.sh              # find "Done" UUID
bash ~/.agents/skills/linear/update-issue.sh "$ARGUMENTS" --state-id <done_uuid>
bash ~/.agents/skills/linear/add-comment.sh "$ARGUMENTS" "Approved & Merged ✅ — \`${BRANCH}\` → \`${TARGET_BRANCH}\`. Branch + worktree cleaned up."
```

---

## Phase 5 — Clean Up

Worktree must be removed before branch deletion:
```bash
git -C "${MAIN_REPO}" worktree remove "${WORKTREE}" --force 2>/dev/null || {
  wtp rm "${BRANCH}" 2>/dev/null || true
}
git -C "${MAIN_REPO}" worktree prune
git -C "${MAIN_REPO}" branch -D "${BRANCH}" 2>/dev/null || true
git -C "${MAIN_REPO}" push origin --delete "${BRANCH}" 2>/dev/null || true
```

---

## Phase 6 — Final Report

```
✅ /ticket-approve $ARGUMENTS complete
  Merged: ${BRANCH} → ${TARGET_BRANCH}
  Worktree: removed | Branch: deleted | Linear: Done
```

---

## Status Transitions

```
Human Review / In Review  →  Done  (after merge + push)
```

## Critical Rules

1. Use `git -C "${MAIN_REPO}"` for all main-repo operations — never `cd`
2. `--ff-only` first, fall back to `--no-ff` on diverged histories
3. Clean working tree on target branch before merging
4. Push before Linear update + cleanup
5. Delete both local and remote branches
6. Move to Done last — only after push succeeds
7. Never force-push protected branches
8. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
