#!/usr/bin/env bash
# autonomous-agent-spec-loop.sh
#
# Spec-feedback loop agent (runtime-agnostic — works in both the Claude and pi
# container variants; the target repo's scripts/spec-loop.sh auto-detects
# whichever CLI is in PATH).
#
# CHANGE-DRIVEN, not time-driven: polls origin/$GIT_BASE_BRANCH every
# $SPEC_LOOP_POLL_INTERVAL_S seconds and re-audits ONLY when new commits have
# landed — and only the spec-map areas whose mapped files actually changed.
# Gap tickets are filed minutes after a merge, intraday. The comparator/filer
# dedup (resolved-gaps.yaml + Linear search by GAP id) keeps repeat runs quiet.
#
# Pipeline per detected change:
#   1. pin: git fetch + checkout origin/$GIT_BASE_BRANCH
#   2. run: bash scripts/spec-loop.sh --changed-since <last-audited-sha>
#      (first run / unknown sha: full audit of all areas)
#   3. persist: commit + push docs/reviews/** so gap-id continuity and the
#      audit trail survive this ephemeral container
#
# Env:
#   SPEC_LOOP_POLL_INTERVAL_S  seconds between branch polls (default: 300)
#   SPEC_LOOP_AREAS            space-separated area filter — forces those areas
#                              every audited change (default: changed-area detection)
#   SPEC_LOOP_PUSH_REPORTS     commit+push docs/reviews after run (default: 0 —
#                              file tickets only; set 1 to also bot-commit reports)
#   SPEC_LOOP_COMMIT_PREFIX    explicit prefix override for the report commit
#                              message. Default empty → the agent CREATES a fresh
#                              per-run Linear tracking ticket and uses its id
#                              (e.g. "GYL-512: "), so each writeback references a
#                              distinct real ticket — never a reused static number.
#   SPEC_LOOP_CREATE_RUN_TICKET  create that per-run tracking ticket when pushing
#                              (default: 1). Set 0 to push with an empty prefix
#                              (only safe on repos with no ticket-requiring hook).
#   LINEAR_TEAM_KEY            team the run ticket is created in (default: GYL)
#   GIT_BASE_BRANCH            branch to audit (default: develop)
#
# Fully generic: the only project-specific input is docs/spec-map.yaml. A cloned
# repo without one makes this agent idle (logs once per new commit, no LLM calls).
#
# Usage:
#   ./scripts/autonomous-agent-spec-loop.sh [--once]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/autonomous-spec-loop-logs"
mkdir -p "$LOG_DIR"

# Scripts are installed into <workspace-repo>/scripts by the entrypoint,
# so the repo root is always the parent of this script's directory.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_BRANCH="${GIT_BASE_BRANCH:-develop}"
POLL_INTERVAL_S="${SPEC_LOOP_POLL_INTERVAL_S:-300}"
PUSH_REPORTS="${SPEC_LOOP_PUSH_REPORTS:-0}"
COMMIT_PREFIX="${SPEC_LOOP_COMMIT_PREFIX:-}"
CREATE_RUN_TICKET="${SPEC_LOOP_CREATE_RUN_TICKET:-1}"
TEAM_KEY="${LINEAR_TEAM_KEY:-GYL}"
STATE_FILE="$LOG_DIR/last-audited-sha"
ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" | tee -a "$LOG_DIR/agent.log"
}

LINEAR_GQL="https://api.linear.app/graphql"

# Create a per-run tracking ticket for the audit writeback and echo its
# identifier (e.g. GYL-512). Lands in a Done/completed state so it records the
# automated run without cluttering the Backlog arbitration buffer. Echoes
# nothing on failure (caller decides whether to proceed).
create_run_ticket() {
    local sha="$1" reports="$2"
    SPEC_SHA="$sha" SPEC_REPORTS="$reports" SPEC_TEAM="$TEAM_KEY" \
    SPEC_DATE="$(date '+%Y-%m-%d %H:%M')" python3 - <<'PY' 2>/dev/null
import json, os, urllib.request

KEY = os.environ["LINEAR_API_KEY"]
TEAM = os.environ["SPEC_TEAM"]
SHA = os.environ["SPEC_SHA"]
REPORTS = os.environ.get("SPEC_REPORTS", "").strip()
DATE = os.environ["SPEC_DATE"]

def gql(query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        "https://api.linear.app/graphql", data=body,
        headers={"Authorization": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)

# Resolve team id
t = gql("query($k:String!){teams(filter:{key:{eq:$k}}){nodes{id}}}", {"k": TEAM})
nodes = t.get("data", {}).get("teams", {}).get("nodes", [])
if not nodes:
    raise SystemExit(1)
team_id = nodes[0]["id"]

# Prefer a completed-type state so the tracking ticket lands in Done
s = gql("query($k:String!){workflowStates(filter:{team:{key:{eq:$k}}}){nodes{id type}}}", {"k": TEAM})
states = s.get("data", {}).get("workflowStates", {}).get("nodes", [])
state_id = next((st["id"] for st in states if st["type"] == "completed"), None)

report_lines = "\n".join(f"- `{p}`" for p in REPORTS.split()) or "- (none)"
desc = (
    "Automated spec-vs-implementation audit writeback by the autoframe "
    "spec-loop agent.\n\n"
    f"**Audited SHA:** `{SHA}`\n**When:** {DATE}\n\n"
    "**Reports refreshed:**\n" + report_lines + "\n\n"
    "Docs-only commit. Gap findings (if any) are filed as separate Backlog "
    "tickets for human arbitration."
)
inp = {"teamId": team_id, "title": f"spec-loop audit {SHA[:12]} ({DATE})", "description": desc}
if state_id:
    inp["stateId"] = state_id

r = gql("mutation($i:IssueCreateInput!){issueCreate(input:$i){success issue{identifier}}}", {"i": inp})
issue = r.get("data", {}).get("issueCreate", {}).get("issue")
if not issue:
    raise SystemExit(1)
print(issue["identifier"])
PY
}

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    log ERROR "LINEAR_API_KEY not set — cannot file gap tickets"
    exit 2
fi

run_audit() {
    local new_sha="$1" last_sha="$2"
    local stamp run_log
    stamp="$(date +%Y%m%d-%H%M%S)"
    run_log="$LOG_DIR/spec-loop-${stamp}.log"

    cd "$REPO_DIR" || { log ERROR "repo not found at $REPO_DIR"; return 1; }

    git checkout -B "$BASE_BRANCH" "$new_sha" >>"$run_log" 2>&1 \
        || { log ERROR "git checkout $new_sha failed"; return 1; }

    if [[ ! -f scripts/spec-loop.sh ]]; then
        log WARN "scripts/spec-loop.sh not present @ ${new_sha:0:12} — entrypoint seeding may have been skipped"
        return 1
    fi

    if [[ ! -f docs/spec-map.yaml ]]; then
        log INFO "No docs/spec-map.yaml in this repo — spec-loop idle @ ${new_sha:0:12}"
        echo "$new_sha" > "$STATE_FILE"
        return 0
    fi

    # ── Run the in-repo loop ──────────────────────────────────────────────────
    local rc
    if [[ -n "${SPEC_LOOP_AREAS:-}" ]]; then
        log INFO "Auditing forced areas: $SPEC_LOOP_AREAS @ ${new_sha:0:12}"
        # shellcheck disable=SC2086
        bash scripts/spec-loop.sh $SPEC_LOOP_AREAS >>"$run_log" 2>&1; rc=$?
    elif [[ -n "$last_sha" ]] && git cat-file -e "$last_sha" 2>/dev/null; then
        log INFO "Auditing changes ${last_sha:0:12}..${new_sha:0:12}"
        bash scripts/spec-loop.sh --changed-since "$last_sha" >>"$run_log" 2>&1; rc=$?
    else
        log INFO "No previous audit state — full audit @ ${new_sha:0:12}"
        bash scripts/spec-loop.sh >>"$run_log" 2>&1; rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
        log ERROR "spec-loop.sh exited rc=$rc — see $run_log"
        return $rc
    fi

    # Stage reports once (intent-to-add covers brand-new gap files) so both the
    # findings notification and the push block see a consistent diff vs HEAD.
    git add docs/reviews/ >>"$run_log" 2>&1

    # ── Surface findings to the feedback channel (best-effort, never blocks) ──
    local changed_gaps finding_count areas_list
    changed_gaps="$(git diff --cached --name-only HEAD -- docs/reviews/gaps/ 2>/dev/null)"
    if [[ -n "$changed_gaps" ]]; then
        finding_count="$(git diff --cached HEAD -- docs/reviews/gaps/ 2>/dev/null | grep -c '^+### GAP-' || true)"
        if [[ "${finding_count:-0}" -gt 0 ]]; then
            areas_list="$(echo "$changed_gaps" | sed -E 's#.*/[0-9-]+-(.*)\.md#\1#' | sort -u | tr '\n' ' ')"
            "$SCRIPT_DIR/notify-human.sh" ":mag: *spec-loop* audited *${areas_list}* @ \`${new_sha:0:12}\` — ${finding_count} new/changed finding(s) filed to the *${TEAM_KEY}* Backlog for arbitration." || true
            log INFO "Notified feedback channel: ${finding_count} finding(s) in ${areas_list}"
        fi
    fi

    # ── Persist gap reports + observed notes back to the remote ──────────────
    if [[ "$PUSH_REPORTS" == "1" ]]; then
        if ! git diff --cached --quiet; then
            # Resolve the commit prefix. An explicit override wins; otherwise the
            # agent creates a fresh per-run tracking ticket and uses ITS id, so
            # we never reuse a single static ticket number across audits.
            local prefix="$COMMIT_PREFIX" reports rt
            if [[ -z "$prefix" && "$CREATE_RUN_TICKET" == "1" ]]; then
                reports="$(git diff --cached --name-only -- docs/reviews/ | tr '\n' ' ')"
                rt="$(create_run_ticket "$new_sha" "$reports")"
                if [[ -n "$rt" ]]; then
                    prefix="${rt}: "
                    log INFO "Created run ticket $rt for audit writeback"
                else
                    log WARN "Could not create run ticket — skipping report push (gap tickets unaffected)"
                    git reset --hard "$new_sha" >>"$run_log" 2>&1
                    echo "$new_sha" > "$STATE_FILE"
                    log INFO "Audit complete @ ${new_sha:0:12} (reports not pushed) — log: $run_log"
                    return 0
                fi
            fi
            if git -c user.name="spec-loop-agent" -c user.email="spec-loop@autoframe.local" \
                commit -m "${prefix}spec-loop audit @ ${new_sha:0:12} ($(date '+%Y-%m-%d %H:%M'))

Automated gap report + observed-behaviour refresh. Docs-only.
Generated by autoframe spec-loop agent." >>"$run_log" 2>&1; then
                if git push origin "$BASE_BRANCH" >>"$run_log" 2>&1; then
                    log INFO "Pushed docs/reviews updates to $BASE_BRANCH"
                    # Record our own report commit so the next poll doesn't
                    # treat it as new upstream work.
                    new_sha="$(git rev-parse HEAD)"
                else
                    log WARN "Push failed (branch moved during audit?) — findings persist in tickets; see $run_log"
                    git reset --hard "$new_sha" >>"$run_log" 2>&1
                fi
            else
                log WARN "Report commit rejected (commit-msg hook?) — findings persist in tickets; see $run_log"
                git reset --hard "$new_sha" >>"$run_log" 2>&1
            fi
        else
            log INFO "No report changes (clean audit or no areas affected)"
        fi
    fi

    echo "$new_sha" > "$STATE_FILE"
    log INFO "Audit complete @ ${new_sha:0:12} — log: $run_log"
}

# ── Main poll loop ────────────────────────────────────────────────────────────

log INFO "spec-loop agent started (poll=${POLL_INTERVAL_S}s, base=$BASE_BRANCH, once=$ONCE)"

while true; do
    cd "$REPO_DIR" 2>/dev/null || { log ERROR "repo not found at $REPO_DIR"; exit 1; }

    if git fetch origin "$BASE_BRANCH" >/dev/null 2>&1; then
        NEW_SHA="$(git rev-parse "origin/$BASE_BRANCH")"
        LAST_SHA="$(cat "$STATE_FILE" 2>/dev/null || true)"

        if [[ "$NEW_SHA" != "$LAST_SHA" ]]; then
            log INFO "New commits on $BASE_BRANCH (${LAST_SHA:0:12} → ${NEW_SHA:0:12})"
            run_audit "$NEW_SHA" "$LAST_SHA" || log WARN "audit failed — will retry next poll"
        fi
    else
        log WARN "git fetch failed — retrying next poll"
    fi

    [[ "$ONCE" == "1" ]] && exit 0
    sleep "$POLL_INTERVAL_S"
done
