#!/usr/bin/env bash
# spec-loop.sh — generic spec-vs-implementation feedback loop.
#
# Bundled with autoframe and seeded into any project that doesn't ship its own
# copy. The ONLY project-specific input is docs/spec-map.yaml. For each active
# area in that map:
#   1. spec-describer  — blind code review → docs/reviews/observed/<area>.md
#   2. spec-comparator — spec vs observed  → docs/reviews/gaps/<date>-<area>.md
#   3. spec-filer      — file new gaps as Linear Backlog tickets (deduped)
#
# Always runs against a PINNED SHA — the caller (the spec-loop agent) git-fetches
# and checks out a fixed commit first. Gap reports must describe a stable snapshot.
#
# Usage:
#   bash scripts/spec-loop.sh                          # all active areas
#   bash scripts/spec-loop.sh mint-at-fill             # explicit area(s)
#   bash scripts/spec-loop.sh --changed-since <sha>    # only areas whose mapped
#                                                      #   spec/code files changed
#                                                      #   between <sha> and HEAD
#                                                      #   (exit 0, no-op if none)
#
# Runtime: auto-detects `claude` (Claude Code) or `pi` in PATH; override with
# SPEC_LOOP_RUNTIME=claude|pi. Agent definitions are seeded into .claude/agents/
# (claude) by the autoframe entrypoint.
#
# Env:
#   LINEAR_API_KEY   (required) — to file gap tickets
#   LINEAR_TEAM_KEY  (default GYL) — Linear team the tickets land in
#   SPEC_LOOP_RUNTIME  claude|pi|auto (default auto)
#
# Exit 0 (no-op) if docs/spec-map.yaml is absent — so the loop is safe to run
# against any repo; it stays quiet until that repo authors a spec-map.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DATE="$(date +%Y-%m-%d)"
TEAM_KEY="${LINEAR_TEAM_KEY:-GYL}"
SPEC_MAP="$REPO_ROOT/docs/spec-map.yaml"

# ── Validate environment ──────────────────────────────────────────────────────

if [[ ! -f "$SPEC_MAP" ]]; then
  echo "No docs/spec-map.yaml in $REPO_ROOT — nothing to audit (spec-loop idle)"
  exit 0
fi

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  echo "ERROR: LINEAR_API_KEY is not set" >&2
  exit 1
fi

RUNTIME="${SPEC_LOOP_RUNTIME:-auto}"
if [[ "$RUNTIME" == "auto" ]]; then
  if command -v claude &>/dev/null; then RUNTIME=claude
  elif command -v pi &>/dev/null; then RUNTIME=pi
  else
    echo "ERROR: neither claude nor pi found in PATH" >&2
    exit 1
  fi
fi
echo "runtime: $RUNTIME  team: $TEAM_KEY"

# ── Pin to current HEAD (caller checks out a fixed SHA before invoking) ───────

PIN_SHA="$(git rev-parse HEAD)"
echo "=== spec-loop  date=$DATE  sha=${PIN_SHA:0:12} ==="

# ── Determine areas ───────────────────────────────────────────────────────────

CHANGED_SINCE=""
if [[ "${1:-}" == "--changed-since" ]]; then
  CHANGED_SINCE="${2:?--changed-since requires a SHA}"
  shift 2
fi

all_areas() {
  grep -E '^  [a-z][a-z0-9-]+:$' "$SPEC_MAP" | sed 's/[: ]//g'
}

if [[ $# -gt 0 ]]; then
  AREAS=("$@")
elif [[ -n "$CHANGED_SINCE" ]]; then
  # Map files changed since $CHANGED_SINCE to the areas that list them.
  # A change to spec-map.yaml itself re-audits everything.
  CHANGED_FILES="$(git diff --name-only "$CHANGED_SINCE"..HEAD)"
  if echo "$CHANGED_FILES" | grep -qx 'docs/spec-map.yaml'; then
    AREAS=()
    while IFS= read -r line; do AREAS+=("$line"); done < <(all_areas)
    echo "spec-map.yaml changed — auditing all areas"
  else
    AREAS=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && AREAS+=("$line")
    done < <(python3 -c "
import re, sys

spec_map = open('$SPEC_MAP').read()
changed = set('''$CHANGED_FILES'''.split())

for m in re.finditer(r'^  ([a-z][a-z0-9-]+):\n(.*?)(?=\n  [a-z]|\Z)', spec_map, re.DOTALL | re.MULTILINE):
    area, block = m.group(1), m.group(2)
    files = set()
    for line in block.splitlines():
        s = line.strip()
        if s.startswith('- ') and not s.startswith('- #'):
            files.add(s[2:].split('#')[0].strip())
    if files & changed:
        print(area)
")
    if [[ ${#AREAS[@]} -eq 0 ]]; then
      echo "No mapped files changed since ${CHANGED_SINCE:0:12} — nothing to audit"
      exit 0
    fi
    echo "Changed areas since ${CHANGED_SINCE:0:12}: ${AREAS[*]}"
  fi
else
  AREAS=()
  while IFS= read -r line; do
    AREAS+=("$line")
  done < <(all_areas)
fi

echo "Areas: ${AREAS[*]}"
echo ""

# ── Run each area ─────────────────────────────────────────────────────────────

for AREA in "${AREAS[@]}"; do
  echo "--- area: $AREA ---"

  OBSERVED="$REPO_ROOT/docs/reviews/observed/${AREA}.md"
  GAP_REPORT="$REPO_ROOT/docs/reviews/gaps/${DATE}-${AREA}.md"
  LEDGER="$REPO_ROOT/docs/reviews/resolved-gaps.yaml"
  mkdir -p "$REPO_ROOT/docs/reviews/observed" "$REPO_ROOT/docs/reviews/gaps"

  # Extract spec files for this area
  SPEC_FILES="$(python3 -c "
import re, sys
content = open('$SPEC_MAP').read()
m = re.search(r'  ${AREA}:\n(.*?)(?=\n  [a-z]|\Z)', content, re.DOTALL)
if not m: sys.exit(1)
block = m.group(1)
in_spec = False
for line in block.splitlines():
    s = line.strip()
    if s == 'spec:': in_spec = True; continue
    if s.endswith(':') and not s.startswith('-') and in_spec: break
    if in_spec and s.startswith('- '): print(s[2:].strip())
")"

  # Extract primary code files for this area
  CODE_FILES="$(python3 -c "
import re, sys
content = open('$SPEC_MAP').read()
m = re.search(r'  ${AREA}:\n(.*?)(?=\n  [a-z]|\Z)', content, re.DOTALL)
if not m: sys.exit(1)
block = m.group(1)
in_code = False
for line in block.splitlines():
    s = line.strip()
    if s == 'code:': in_code = True; continue
    if s.endswith(':') and not s.startswith('-') and in_code: break
    if in_code and s.startswith('- ') and not s.startswith('- #'):
        print(s[2:].split('#')[0].strip())
")"

  echo "  spec: $(echo "$SPEC_FILES" | wc -l | tr -d ' ') file(s)"
  echo "  code: $(echo "$CODE_FILES" | wc -l | tr -d ' ') file(s)"

  # Build the three-step task prompt. The runtime invokes each agent as an
  # ISOLATED subagent (Claude Code: Task tool; pi: subagent chain tool).
  TASK="$(cat <<TASK
Run the spec-feedback loop for area '${AREA}' in repo ${REPO_ROOT} (SHA ${PIN_SHA}).

Execute these three steps IN ORDER, each as an ISOLATED subagent
(Claude Code: Task tool with the named agent from .claude/agents/;
pi: subagent chain tool with the named agent from .agents/skills/).
Each step must fully complete before the next begins — step 2 reads the
file step 1 writes, and step 3 reads the file step 2 writes.
Do NOT perform any step yourself in the main session — step 1's blindness
to docs/ only holds inside an isolated subagent context.

STEP 1 — agent: spec-describer
Task: "Area: ${AREA}. SHA: ${PIN_SHA}.
Read ONLY these code files (cwd: ${REPO_ROOT}):
$(echo "$CODE_FILES" | sed 's/^/- /')

Do NOT read any file under docs/. Write your full report to: ${OBSERVED}"

STEP 2 — agent: spec-comparator
Task: "Area: ${AREA}. Date: ${DATE}.
Inputs (cwd: ${REPO_ROOT}):
1. Spec docs:
$(echo "$SPEC_FILES" | sed 's/^/   - /')
2. Observed behaviour (just written by describer): ${OBSERVED}
3. Resolved-gaps ledger: ${LEDGER}
Write gap report to: ${GAP_REPORT}"

STEP 3 — agent: spec-filer
Task: "Area: ${AREA}. Date: ${DATE}.
Gap report: ${GAP_REPORT}
Resolved-gaps ledger: ${LEDGER}
Team: ${TEAM_KEY}
File all new findings as Backlog tickets (deduped). Patch the gap report with ticket ids."
TASK
)"

  # Run non-interactively via the detected runtime
  LOG_FILE="/tmp/spec-loop-${AREA}-${DATE}.log"
  echo "  log: $LOG_FILE"

  if [[ "$RUNTIME" == "claude" ]]; then
    claude --dangerously-skip-permissions \
      --no-session-persistence \
      -p "$TASK" \
      > "$LOG_FILE" 2>&1 \
      && echo "  ✓ done: $GAP_REPORT" \
      || echo "  ✗ FAILED — see $LOG_FILE"
  else
    pi --print \
      --no-session \
      "$TASK" \
      > "$LOG_FILE" 2>&1 \
      && echo "  ✓ done: $GAP_REPORT" \
      || echo "  ✗ FAILED — see $LOG_FILE"
  fi

  echo ""
done

echo "=== spec-loop complete ==="
