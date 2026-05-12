---
description: Scaffold a new autonomous agent — generates the shell script, ticket command, and wires it into setup.sh and README
runInPlanMode: false
scope: project
---

Scaffold a complete autonomous agent: shell polling script, ticket command definition, and updates to `setup.sh` and `README.md`.

**Uses the Linear skill (`~/.agents/skills/linear/`) for all Linear API interactions in generated templates.**

## Request

{{ARGUMENTS}}

---

## Phase 1 — Gather Requirements

Parse `{{ARGUMENTS}}` for:

- **Agent name** — e.g. `triage`, `research`, `qa` (used in filenames and command names)
- **Poll status** — the Linear state name(s) this agent picks up from, e.g. `"Todo"` or `"Todo","Backlog"`
- **Working status** — the Linear state the agent sets while it is working, e.g. `"In Progress"`
- **Done status** — the Linear state the agent sets when it finishes, e.g. `"Pending Review"`
- **Description** — one sentence describing what this agent does

If any of the above are missing or ambiguous, use `AskUserQuestion` to gather them one at a time. Do not proceed to Phase 2 without all five values confirmed.

Present a summary before generating:

```
Agent name   : autonomous-agent-{name}.sh
Command      : /ticket-{name}
Polls        : "{poll_status}"
Sets working : "{working_status}"
Sets done    : "{done_status}"
Description  : {description}
```

Ask: *"Generate with these settings? (yes / edit: <changes>)"*

---

## Phase 2 — Design the Command Phases

Before writing any files, design the phases for `/ticket-{name}`. Use `AskUserQuestion` to present a draft phase breakdown and confirm it with the user.

Default phase template to propose (adapt to the agent's purpose):

```
Phase 1 — Fetch & Claim
  - Fetch ticket details, statuses via Linear skill scripts
  - Set status to "{working_status}"
  - Post a claiming comment

Phase 2 — [Core work phase name]
  - [Main action this agent performs]

Phase 3 — [Secondary work phase, if needed]
  - [Supporting action]

Phase 4 — Post Output & Transition
  - Post results as a ticket comment
  - Set status to "{done_status}"
  - Post a next-step comment
```

Ask: *"Does this phase structure look right, or would you like to adjust?"*

Incorporate any feedback before proceeding to Phase 3.

---

## Phase 3 — Generate the Command File

Create `.claude/commands/ticket-{name}.md` with the confirmed phase structure. Use the existing commands as style references — be specific, actionable, and include an orchestration map at the end.

Template structure:

```markdown
---
description: {description} — moves ticket from {poll_status} to {done_status}
runInPlanMode: false
scope: project
---

{One paragraph description of what this command does and its place in the pipeline.}

**Uses the Linear skill (`~/.agents/skills/linear/`) for all Linear API interactions.**

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 1 — Fetch & Claim

Fetch ticket details (includes comments) and workflow states:

\```bash
bash ~/.agents/skills/linear/get-issue.sh "{{ARGUMENTS}}"
bash ~/.agents/skills/linear/list-states.sh
\```

Set status to `{working_status}`:

\```bash
# Find the "{working_status}" state UUID from list-states.sh output, then:
bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <{working_status}_uuid>
\```

Post a claiming comment describing what will happen:

\```bash
bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "[Claiming message]"
\```

---

## Phase 2 — [Core Phase Name]

[Detailed instructions for the core work]

---

## Phase N — Post Output & Transition

1. Post the results as a ticket comment:
   \```bash
   bash ~/.agents/skills/linear/add-comment.sh "{{ARGUMENTS}}" "$(cat <<'OUTPUT'
   [output markdown]
   OUTPUT
   )"
   \```

2. Set ticket status to `{done_status}`:
   \```bash
   # Find the "{done_status}" state UUID from list-states.sh output, then:
   bash ~/.agents/skills/linear/update-issue.sh "{{ARGUMENTS}}" --state-id <{done_status}_uuid>
   \```

3. Post a next-step comment indicating what the human or next agent should do.

---

## Status Transitions

\```
{poll_status}    →  {working_status}   (Phase 1)
{working_status} →  {done_status}      (Phase N)
\```

## Critical Rules

1. [Key rule for this agent]
2. [Key rule for this agent]
3. **No code changes** — if this is a read/analysis agent
4. **Post to Linear** — output lives as ticket comments
5. **Claim before working** — set `{working_status}` as the very first mutation
6. **Use the Linear skill** — all Linear API interactions go through `~/.agents/skills/linear/` scripts, not MCP tool calls.

## Orchestration Map

\```
/ticket-{name} TICKET-XX
        │
        ▼
Phase 1: Fetch & Claim
  get-issue.sh + list-states.sh → update-issue.sh: {working_status}
        │
        ▼
Phase 2: [Core work]
        │
        ▼
Phase N: Post & Transition
  add-comment.sh: output
  update-issue.sh: {done_status}
\```
```

---

## Phase 4 — Generate the Shell Script

Create `scripts/autonomous-agent-{name}.sh` following the canonical pattern. Key values to substitute:

| Placeholder | Value |
|-------------|-------|
| `{name}` | agent name |
| `{POLL_STATUSES}` | GraphQL `in:[...]` list for the poll query |
| `{ACTIONABLE_CHECK}` | bash condition in `ticket_still_actionable` |
| `{EMOJI}` | tool-call emoji in stream processor (pick one that fits the role) |
| `{VERB}` | present participle for heartbeat message, e.g. "researching", "planning" |
| `{LOG_DIR}` | `autonomous-{name}-logs` |
| `{PROCESSED_FILE}` | `/tmp/autonomous-{name}-processed.txt` |
| `{LOCK_PREFIX}` | `{name}-lock` |
| `{COMMAND}` | `/ticket-{name}` |

The script must:
- Load `LINEAR_API_KEY` and `LINEAR_TEAM_KEY` from `.auto-claude/.env` (with env var fallback)
- Use `LINEAR_TEAM_KEY` in the GraphQL filter (not a hardcoded team key)
- Use `[A-Z]+-[0-9]+` regex in `parse_ticket_ids`
- Use `--dangerously-skip-permissions --no-session-persistence` when calling `claude`
- Include the watchdog timeout, heartbeat, phase summary, and signal handling exactly as in the other agents

After writing the file, make it executable:
```bash
chmod +x scripts/autonomous-agent-{name}.sh
```

---

## Phase 5 — Wire into setup.sh and README

### setup.sh

Add to the `SCRIPTS` array (in pipeline order):
```bash
"scripts/autonomous-agent-{name}.sh"
```

Add to the `COMMANDS` array:
```bash
".claude/commands/ticket-{name}.md"
```

Add to the run instructions block:
```bash
echo -e "     ${CYAN}./scripts/autonomous-agent-{name}.sh${RESET}  # {description}"
```

Add `{poll_status}`, `{working_status}`, and `{done_status}` to the Linear states list if not already present.

### README.md

Add the new agent to the pipeline diagram in the correct position based on `{poll_status}`.

Add to the Linear state table any new states this agent introduces.

Add a `### /ticket-{name}` section under "What Each Command Does" describing the phases.

Add to the Running in Parallel stale-lock cleanup command:
```bash
/tmp/{name}-lock-*
```

---

## Phase 6 — Summary

Print a checklist of everything created:

```
✓ .claude/commands/ticket-{name}.md
✓ scripts/autonomous-agent-{name}.sh  (executable)
✓ setup.sh — SCRIPTS and COMMANDS updated
✓ README.md — pipeline, state table, command docs updated
```

Then show the pipeline position of the new agent and the next steps for the user:

```
Pipeline position:
  {poll_status} → [autonomous-agent-{name}.sh] → {working_status} → {done_status}

Next steps:
  1. Create the Linear workflow states if they don't exist yet
  2. Run: ./scripts/autonomous-agent-{name}.sh --once   (test with one ticket)
  3. If this is for the autoframe template, copy the new files there too
```

---

## Critical Rules

1. **Confirm before generating** — always show the settings summary and get explicit approval in Phase 1
2. **Confirm phases before writing** — show the phase breakdown and get approval in Phase 2
3. **Follow the canonical shell script pattern exactly** — use `LINEAR_TEAM_KEY`, generic ticket regex, watchdog, heartbeat, signal handlers
4. **Wire everything** — a new agent is only complete when setup.sh and README.md are updated
5. **Make the script executable** — `chmod +x` immediately after writing
6. **Use the Linear skill in templates** — generated command files must reference `~/.agents/skills/linear/` scripts, not MCP tool calls.
