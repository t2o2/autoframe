---
description: Research a Linear ticket — explore the codebase and post findings as a ticket comment, then move to Research Pending Approval
runInPlanMode: false
scope: project
---

Research a Linear ticket by exploring the codebase and posting a structured research document as a ticket comment. Moves the ticket `Todo → Research → Research Pending Approval`.

## Request

Ticket ID: {{ARGUMENTS}}

---

## Phase 1 — Fetch & Claim

Fetch everything in parallel:

1. `mcp__linear-server__get_issue` — full ticket details
2. `mcp__linear-server__list_issue_statuses` — valid status IDs for the team
3. `mcp__linear-server__list_comments` — any prior discussion or previous attempt notes

Parse and record: title, description, priority, labels, team ID.

Set status to `Research`:

```
mcp__linear-server__save_issue → { id, statusId: <research_id> }
```

Post a claiming comment:
> "Picking up research for {{ARGUMENTS}}. Exploring codebase to understand scope, relevant files, and implementation context before planning begins."

If description is too vague (< 2 actionable sentences), ask via Telegram before proceeding:

```
Bash: ./scripts/ask-human.sh {{ARGUMENTS}} "Ticket description is too vague to research. What is the goal?" "Clarify in Linear and re-trigger" "Describe the intended behaviour here"
```

Use the returned text as the clarification context. If the script exits 2 (no credentials), fall back to `AskUserQuestion`.

---

## Phase 2 — Identify Research Areas

Read the ticket description carefully and decompose it into research areas. Before spawning sub-agents, identify:

- Which services / components does this ticket likely touch?
- What existing patterns are relevant to follow?
- What data models, API shapes, or interfaces are involved?
- Are there related tickets or prior implementations in the comments?
- What are the risk areas or unknowns?

This analysis drives which sub-agents to spawn in Phase 3.

---

## Phase 3 — Parallel Codebase Exploration

Spawn multiple `Explore` agents in parallel — each focused on a specific research area. Adapt agents to the ticket; these are representative examples:

Each sub-agent prompt must lead with its prohibition contract before its task:

- **SCOPE AGENT**
  `MUST NOT: Suggest improvements. Critique code quality. Speculate about what should change. Recommend refactors.`
  `ONLY DO: Find all files that implement or reference [feature area]. List file paths, function names, and a one-sentence description of what each does. If nothing found, say so explicitly. Return concrete file:line references only.`

- **PATTERN AGENT**
  `MUST NOT: Critique existing patterns. Suggest better approaches. Recommend changes.`
  `ONLY DO: Find existing patterns in the codebase similar to [what this ticket requires]. Show me examples to follow, not critiques to fix. Return file:line references and describe what each pattern does — nothing more.`

- **TEST AGENT**
  `MUST NOT: Assess test quality. Suggest missing tests. Recommend improvements.`
  `ONLY DO: Find existing tests for [the affected component]. Return file paths, what behaviors each test covers, and the test setup helpers available. Document what exists — not what should exist.`

- **SCHEMA / TYPES AGENT**
  `MUST NOT: Suggest schema changes. Flag normalization issues. Recommend type improvements.`
  `ONLY DO: Find database schema definitions, Rust structs/enums, or TypeScript interfaces related to [the area]. Return file:line references and the exact type definitions. No commentary.`

Wait for **ALL** sub-agents to complete before proceeding to Phase 4.

---

## Phase 4 — Synthesize Research

Compile all sub-agent findings into a structured research document. Be factual and concrete — no filler.

```markdown
## Research: {{ARGUMENTS}} — [Ticket Title]

**Ticket:** [title]
**Type:** [bug / feature / improvement / chore]
**Researched:** [ISO date]

### Summary
[2–4 sentences: what the ticket actually touches, what was found, overall complexity read]

### Relevant Files

| File | What it does | Relevance to ticket |
|------|-------------|---------------------|
| `path/to/file.rs:42` | [description] | [why relevant] |

### Current Implementation
[How the relevant code works today — with file:line refs. Describe behaviour, not quality.]

### Patterns to Follow
[Existing patterns in the codebase that the implementation should mirror]
- `path/to/example.rs:100` — [pattern description]

### Existing Tests
[Test files and what they cover — informs what the implementer will need to add]
- `path/to/tests.rs` — covers [X, Y, Z]

### Complexity Assessment
- **Estimated scope:** [trivial / small / medium / large]
- **Risk areas:** [e.g., "touches auth middleware — needs regression testing for all authed endpoints"]
- **Blockers / unknowns:** [anything that couldn't be resolved from the code alone]

### Key Decisions for the Planner
[Only if there are genuine ambiguities that require a design choice before planning]
- [question]: [what was found vs what is unclear]
```

---

## Phase 5 — Post Research & Transition

1. Post the full research document as a ticket comment:

   `mcp__linear-server__save_comment` → `{ issue: "{{ARGUMENTS}}", body: <research document> }`

2. Set ticket status to `Research Pending Approval`:

   `mcp__linear-server__save_issue` → `{ id, statusId: <pending_research_approval_id> }`

3. Post a final summary comment:
   > "Research complete. Findings posted above. **Next step:** review the research and move ticket to **Research Approved** to trigger the planning agent."

4. Write research artifact to the persistent thought store:

   ```bash
   mkdir -p "thoughts/tickets/{{ARGUMENTS}}"
   ```

   Write to `thoughts/tickets/{{ARGUMENTS}}/research.md`:

   ```markdown
   ---
   ticket: {{ARGUMENTS}}
   title: [ticket title]
   type: [bug / feature / improvement / chore]
   researched: [ISO date]
   status: pending_approval
   complexity: [trivial / small / medium / large]
   ---

   ## Summary
   [copy from research document — 2–4 sentences]

   ## Relevant Files
   [copy the file table from the research document]

   ## Patterns to Follow
   [copy from research document]

   ## Key Decisions for the Planner
   [copy from research document, or "none"]
   ```

   This artifact is read by `/ticket-plan` and `/ticket-process` to avoid re-parsing Linear comments.

---

## Status Transitions

```
Todo       →  Research                    (Phase 1)
Research   →  Research Pending Approval   (Phase 5)
```

## Critical Rules

1. **Claim before exploring** — set `Research` status as the very first mutation
2. **Document what IS** — never suggest changes or improvements; research is read-only
3. **Concrete file:line references** — every finding must cite a specific location
4. **Post to Linear** — research lives as a ticket comment, not just local output
5. **No code changes** — this command does not touch any file in the repository
6. **Wait for all sub-agents** — synthesize only after every parallel agent has returned

## Orchestration Map

```
/ticket-research GYL-XX
        │
        ▼
Phase 1: Fetch & Claim
  get_issue + list_issue_statuses + list_comments  [parallel]
  save_issue: Research
  save_comment: "picking up research"
        │
        ├── vague? → AskUserQuestion
        │
        ▼
Phase 2: Identify Research Areas
  decompose ticket into investigation topics
        │
        ▼
Phase 3: Parallel Codebase Exploration  [all agents in parallel]
  ┌─────────────────────┐ ┌─────────────────────┐
  │  Explore (scope)    │ │  Explore (patterns)  │
  └──────────┬──────────┘ └──────────┬───────────┘
             │                       │
  ┌──────────┴──────────┐ ┌──────────┴───────────┐
  │  Explore (tests)    │ │  Explore (schema)     │
  └──────────┬──────────┘ └──────────┬───────────┘
             └───────────┬───────────┘
                         ▼ (wait for all)
Phase 4: Synthesize Research
  compile findings → structured research document
                         │
                         ▼
Phase 5: Post & Transition
  save_comment: research document
  save_issue: Research Pending Approval
  save_comment: "next step: move to Research Approved"
  write: thoughts/tickets/{{ARGUMENTS}}/research.md
```
