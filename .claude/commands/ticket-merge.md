---
description: Merge an approved ticket branch onto the main branch (or parent ticket's branch), push to remote, and clean up the worktree and branch
runInPlanMode: false
scope: project
---

Merge ticket branch onto target, push, clean up worktree + branch. Uses ff-only → no-ff fallback. All Linear API via `~/.agents/skills/linear/` scripts.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Inputs — Artifacts First

This stage is purely mechanical (merge + cleanup) and needs **no** comment thread — only ticket metadata (`parentId`, branch). Never pull the thread here.

- **Metadata fetch (no thread):** `bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'`

`get-issue.sh` always embeds the full comment thread; the `del(.comments)` projection strips it inside the subprocess, keeping it out of context.

---

## Phase 0 — Identify Context

```bash
MAIN_REPO=$(git rev-parse --show-toplevel)
TICKET="{{ARGUMENTS}}"
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

Check for parent ticket in Linear (metadata only — no thread):
```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}" | jq 'del(.comments)'
```

If `parentId` exists → fetch parent → resolve parent's branch (`feat/` or `fix/`). If parent branch not found → fall back to main branch.

No parent → `TARGET_BRANCH="${GIT_BASE_BRANCH:-develop}"`.

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

### Auto-resolve LESSONS.md conflicts (append-only union)

The retro stage commits append-only blocks to `thoughts/retrospectives/LESSONS.md`, so two branches can both append and trigger an add/add conflict on **only** that file. Because every block is additive and ticket-tagged, the correct resolution is always "keep both". If the merge conflicts and the **only** conflicted path is `LESSONS.md`, resolve by union and continue — otherwise stop and report (real conflicts are never auto-resolved):

```bash
LESSONS_PATH="thoughts/retrospectives/LESSONS.md"
CONFLICTS=$(git -C "${MAIN_REPO}" diff --name-only --diff-filter=U)
if [ "${CONFLICTS}" = "${LESSONS_PATH}" ]; then
  TMP=$(mktemp -d)
  git -C "${MAIN_REPO}" show ":1:${LESSONS_PATH}" > "${TMP}/base"  2>/dev/null || : > "${TMP}/base"
  git -C "${MAIN_REPO}" show ":2:${LESSONS_PATH}" > "${TMP}/ours"
  git -C "${MAIN_REPO}" show ":3:${LESSONS_PATH}" > "${TMP}/theirs"
  git merge-file -p --union "${TMP}/ours" "${TMP}/base" "${TMP}/theirs" \
    > "${MAIN_REPO}/${LESSONS_PATH}"
  git -C "${MAIN_REPO}" add "${LESSONS_PATH}"
  rm -rf "${TMP}"
  git -C "${MAIN_REPO}" commit --no-edit   # completes the in-progress merge
elif [ -n "${CONFLICTS}" ]; then
  echo "Merge conflict in non-LESSONS files — aborting for human review:"
  echo "${CONFLICTS}"
  git -C "${MAIN_REPO}" merge --abort
  exit 1
fi
```

---

## Phase 3 — Push

```bash
git -C "${MAIN_REPO}" push origin "${TARGET_BRANCH}"
```

---

## Phase 4 — Update Linear

```bash
bash ~/.agents/skills/linear/list-states.sh        # find "Done" UUID
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <done_uuid>
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "Approved & Merged ✅ — \`${BRANCH}\` → \`${TARGET_BRANCH}\`. Branch + worktree cleaned up."
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
✅ /ticket-merge {{ARGUMENTS}} complete
  Merged: ${BRANCH} → ${TARGET_BRANCH}
  Worktree: removed | Branch: deleted | Linear: Done
```

---

## Status Transitions

```
Merge  →  Done  (after merge + push)
```

## Critical Rules

1. Use `git -C "${MAIN_REPO}"` for all main-repo operations — never `cd`
2. Metadata only — never pull the comment thread (fetch uses `jq 'del(.comments)'`)
3. `--ff-only` first, fall back to `--no-ff` on diverged histories
4. Only `thoughts/retrospectives/LESSONS.md` may be auto-resolved (append-only union). Any other conflicted file → `merge --abort` and stop for a human
5. Clean working tree on target branch before merging
6. Push before Linear update + cleanup
7. Delete both local and remote branches
8. Move to Done last — only after push succeeds
9. Never force-push protected branches
10. All Linear API via `~/.agents/skills/linear/` scripts, not MCP tools
