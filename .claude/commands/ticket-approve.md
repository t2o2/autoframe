---
description: Rebase an approved ticket branch onto the main branch (or parent ticket's branch), fast-forward merge, push to remote, and clean up the worktree and branch
runInPlanMode: false
scope: project
---

Rebase a reviewed and approved ticket branch onto the correct target branch, fast-forward merge, push the result to origin, then remove the worktree and delete the branch both locally and remotely — leaving the repository in a clean state.

**Why rebase instead of merge:** Rebasing replays the ticket's commits on top of the latest `${TARGET_BRANCH}`, preserving all changes that have landed since the branch was cut. A `--no-ff` merge can silently overwrite concurrent changes when conflicts are absent; rebase + fast-forward avoids this by always building on the latest state.

**Target branch logic:** If the ticket has a parent ticket in Linear, rebase onto the parent's branch (e.g. `feat/TICKET-24`) instead of the main branch. This keeps sub-ticket work isolated in the parent feature branch until the parent is approved.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 0 — Resolve Branch & Worktree

Determine which branch and worktree belong to this ticket. Try both prefixes:

```bash
TICKET="{{ARGUMENTS}}"

# Detect branch — prefer feat/, fall back to fix/
if git show-ref --verify --quiet "refs/heads/feat/${TICKET}"; then
  BRANCH="feat/${TICKET}"
elif git show-ref --verify --quiet "refs/heads/fix/${TICKET}"; then
  BRANCH="fix/${TICKET}"
else
  # Try remote
  BRANCH=$(git branch -r | grep -E "(feat|fix)/${TICKET}$" | head -1 | sed 's|origin/||' | tr -d ' ')
fi

if [ -z "${BRANCH}" ]; then
  echo "ERROR: No local or remote branch found for ${TICKET}"
  exit 1
fi

WORKTREE="../worktrees/${BRANCH}"
echo "Branch: ${BRANCH}"
echo "Worktree: ${WORKTREE}"
```

**If no branch is found** — stop and report:
> "Cannot approve {{ARGUMENTS}}: no branch `feat/{{ARGUMENTS}}` or `fix/{{ARGUMENTS}}` found locally or on origin. Has `/ticket-process` been run?"

---

## Phase 0.5 — Resolve Merge Target (Parent Branch or main)

Check whether {{ARGUMENTS}} has a parent ticket in Linear:

1. Call `mcp__linear-server__get_issue` with identifier `{{ARGUMENTS}}`
2. If the response includes a `parentId`, call `mcp__linear-server__get_issue` with that `parentId` to get the parent's `identifier` (e.g. `TICKET-24`)
3. Resolve the parent's branch:

```bash
PARENT_TICKET="<parent identifier>"  # e.g. TICKET-24

if git show-ref --verify --quiet "refs/heads/feat/${PARENT_TICKET}"; then
  TARGET_BRANCH="feat/${PARENT_TICKET}"
elif git show-ref --verify --quiet "refs/heads/fix/${PARENT_TICKET}"; then
  TARGET_BRANCH="fix/${PARENT_TICKET}"
else
  # Try remote
  TARGET_BRANCH=$(git branch -r | grep -E "(feat|fix)/${PARENT_TICKET}$" | head -1 | sed 's|origin/||' | tr -d ' ')
fi

if [ -z "${TARGET_BRANCH}" ]; then
  echo "WARNING: Parent ticket ${PARENT_TICKET} exists but its branch was not found locally or on origin."
  echo "Falling back to main branch."
  TARGET_BRANCH="<your-main-branch>"  # e.g. develop, main, master
fi
```

4. If there is **no parent ticket**, set `TARGET_BRANCH` to your project's main integration branch (e.g. `develop`, `main`, `master`).

Log the resolved target:

```bash
echo "Merge target: ${TARGET_BRANCH}"
```

---

## Phase 1 — Pre-Rebase Safety Checks

Run all checks before touching `${TARGET_BRANCH}`:

**1a. Confirm the branch is up-to-date with origin:**

```bash
git fetch origin "${BRANCH}"
LOCAL=$(git rev-parse "${BRANCH}")
REMOTE=$(git rev-parse "origin/${BRANCH}" 2>/dev/null || echo "not-pushed")

if [ "${LOCAL}" != "${REMOTE}" ]; then
  echo "WARNING: Local branch diverges from origin/${BRANCH}. Fetching latest..."
  git checkout "${BRANCH}" && git pull origin "${BRANCH}"
fi
```

**1b. Confirm target branch is up-to-date:**

```bash
git fetch origin "${TARGET_BRANCH}"
git checkout "${TARGET_BRANCH}"
git pull origin "${TARGET_BRANCH}"
```

**1c. Check for potential rebase conflicts (dry run):**

```bash
git merge-tree $(git merge-base "${BRANCH}" "${TARGET_BRANCH}") "${TARGET_BRANCH}" "${BRANCH}" | grep -c "^<<<" || true
```

If conflicts are detected — warn but proceed; the rebase will surface them clearly and abort automatically if they exist.

**1d. Show what will be rebased (for audit trail):**

```bash
git log ${TARGET_BRANCH}..${BRANCH} --oneline
git diff ${TARGET_BRANCH}...${BRANCH} --stat
```

---

## Phase 2 — Rebase onto Target Branch, then Fast-Forward

**Step 2a — Rebase the ticket branch onto `${TARGET_BRANCH}`:**

This replays the ticket's commits on top of the latest state of `${TARGET_BRANCH}`, ensuring no concurrent changes are silently lost.

```bash
git checkout "${BRANCH}"
git rebase "${TARGET_BRANCH}"
```

If the rebase fails due to conflicts — abort and report:

```bash
git rebase --abort 2>/dev/null || true
echo "Rebase failed due to conflicts. Branch ${TARGET_BRANCH} is unchanged."
echo "Resolve conflicts manually on ${BRANCH} then re-run /ticket-approve {{ARGUMENTS}}."
exit 1
```

**Step 2b — Fast-forward `${TARGET_BRANCH}` to include the rebased commits:**

```bash
git checkout "${TARGET_BRANCH}"
git merge --ff-only "${BRANCH}"
```

If the fast-forward fails (should not happen after a clean rebase) — abort and report:

```bash
echo "Fast-forward failed unexpectedly. ${TARGET_BRANCH} is unchanged. Investigate and re-run."
exit 1
```

---

## Phase 3 — Push Target Branch to Remote

```bash
git push origin "${TARGET_BRANCH}"
```

Confirm the push succeeded by checking the remote tip matches local:

```bash
git fetch origin "${TARGET_BRANCH}"
[ "$(git rev-parse "${TARGET_BRANCH}")" = "$(git rev-parse "origin/${TARGET_BRANCH}")" ] && echo "Push verified." || echo "WARNING: push may have failed — check manually."
```

---

## Phase 4 — Update Linear Ticket

Fetch current statuses and move the ticket to Done:

1. `mcp__linear-server__list_issue_statuses` — find the "Done" status ID
2. Resolve the git user email to use as the Linear assignee:

   ```bash
   GIT_EMAIL=$(git config user.email)
   ```

3. `mcp__linear-server__save_issue` → `{ id: "<ticket-id>", statusId: "<done_id>", assignee: "<GIT_EMAIL>" }`
4. `mcp__linear-server__save_comment`:

```markdown
## Approved & Merged ✅ — {{ARGUMENTS}}

**Branch merged:** `${BRANCH}` → `${TARGET_BRANCH}`
**Merged at:** [current UTC timestamp]
**Pushed:** origin/${TARGET_BRANCH}

Branch and worktree have been cleaned up. Repository is back to a clean state.
```

> **Note:** If `${TARGET_BRANCH}` is a parent feature branch (not the main branch), the parent ticket remains open — only this sub-ticket is marked Done.

---

## Phase 5 — Clean Up Worktree

Remove the worktree if it exists:

```bash
# Try wtp first (preferred — keeps wtp registry clean)
if wtp ls 2>/dev/null | grep -q "${BRANCH}"; then
  wtp rm "${BRANCH}" 2>/dev/null || wtp rm -f "${BRANCH}"
  echo "Removed worktree via wtp: ${BRANCH}"
elif [ -d "${WORKTREE}" ]; then
  # Fallback: remove with git directly
  git worktree remove "${WORKTREE}" 2>/dev/null || git worktree remove --force "${WORKTREE}"
  echo "Removed worktree at ${WORKTREE}"
else
  echo "No worktree found for ${BRANCH} — skipping."
fi

# Prune stale worktree references
git worktree prune
```

---

## Phase 6 — Delete Branch (Local + Remote)

```bash
# Delete local branch
git branch -d "${BRANCH}" 2>/dev/null || git branch -D "${BRANCH}"
echo "Deleted local branch: ${BRANCH}"

# Delete remote branch
git push origin --delete "${BRANCH}"
echo "Deleted remote branch: origin/${BRANCH}"

# Prune remote-tracking refs
git remote prune origin
```

Verify cleanup:

```bash
echo "--- Local branches remaining ---"
git branch | grep "${TICKET}" || echo "(none)"

echo "--- Remote branches remaining ---"
git branch -r | grep "${TICKET}" || echo "(none)"

echo "--- Worktrees remaining ---"
git worktree list | grep "${TICKET}" || echo "(none)"
```

---

## Phase 7 — Final Report

Print a concise summary:

```
✅ /ticket-approve {{ARGUMENTS}} complete

  Branch rebased : ${BRANCH} → rebased onto ${TARGET_BRANCH}
  Fast-forwarded : ${TARGET_BRANCH} (ff-only, no merge commit)
  Remote pushed  : origin/${TARGET_BRANCH} (verified)
  Worktree       : removed
  Local branch   : deleted
  Remote branch  : deleted
  Linear status  : Done

Repository is clean.
```

---

## Worktree Convention

| Attribute | Value |
|---|---|
| Branch patterns | `feat/{{ARGUMENTS}}` or `fix/{{ARGUMENTS}}` |
| Worktree path | `../worktrees/<branch>` |
| Integration strategy | `git rebase ${TARGET_BRANCH}` then `git merge --ff-only` |
| Branch cleanup | Deleted locally and on `origin` |
| Worktree cleanup | Removed via `wtp rm` or `git worktree remove` |

## Target Branch Logic

| Ticket has parent? | Target branch |
|---|---|
| No | Your main integration branch (develop / main / master) |
| Yes, parent branch found | `feat/<parent-id>` or `fix/<parent-id>` |
| Yes, parent branch missing | Falls back to main branch with a warning |

## Status Transitions

```
Human Review / In Review  →  Done   (after successful merge + push)
```

Note: Only the sub-ticket moves to Done. The parent ticket stays open until all sub-tickets are merged and the parent itself is approved.

## Critical Rules

1. **Always fetch before rebasing** — never rebase onto stale branches
2. **Rebase aborts on conflict** — if `git rebase` exits non-zero, run `git rebase --abort` and stop; never force-resolve
3. **Rebase then fast-forward only** — `git rebase ${TARGET_BRANCH}` on `${BRANCH}`, then `git merge --ff-only ${BRANCH}` on `${TARGET_BRANCH}`; this guarantees ticket commits land on top of the latest state
4. **Push before cleanup** — verify `${TARGET_BRANCH}` is on origin before deleting anything
5. **Delete both local and remote** — a half-cleaned branch causes confusion for future agents
6. **Move ticket to Done last** — only after the push is verified; never on merge alone
7. **Never force-push protected branches** — if the push fails, investigate rather than using `--force`

## Orchestration Map

```
/ticket-approve TICKET-XX
        │
        ▼
Phase 0: Resolve branch name
  git show-ref feat/TICKET-XX || fix/TICKET-XX
        │
        ├── not found? → report + exit
        │
        ▼
Phase 0.5: Resolve merge target
  get_issue(TICKET-XX) → check parentId
  ├── no parent → TARGET_BRANCH=<main branch>
  └── parent found → get_issue(parentId) → resolve feat/parent or fix/parent
                      ├── branch found → TARGET_BRANCH=feat/TICKET-YY
                      └── branch missing → TARGET_BRANCH=<main branch> (warn)
        │
        ▼
Phase 1: Safety checks [parallel]
  git fetch + pull origin ${TARGET_BRANCH}
  git fetch + pull origin ${BRANCH}
  merge-tree conflict detection
        │
        ├── conflicts? → report + exit
        │
        ▼
Phase 2: Rebase + fast-forward
  git checkout ${BRANCH}
  git rebase ${TARGET_BRANCH}
  git checkout ${TARGET_BRANCH}
  git merge --ff-only ${BRANCH}
        │
        ├── rebase conflicts? → git rebase --abort + report + exit
        │
        ▼
Phase 3: Push ${TARGET_BRANCH}
  git push origin ${TARGET_BRANCH}
  verify local == origin/${TARGET_BRANCH}
        │
        ▼
Phase 4: Update Linear
  list_issue_statuses → find Done
  save_issue: Done
  save_comment: merge summary
        │
        ▼
Phase 5: Remove worktree
  wtp rm ${BRANCH} || git worktree remove
  git worktree prune
        │
        ▼
Phase 6: Delete branch
  git branch -d ${BRANCH}
  git push origin --delete ${BRANCH}
  git remote prune origin
        │
        ▼
Phase 7: Final report
  Print summary + verify no leftover refs
```
