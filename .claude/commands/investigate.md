---
description: Investigate bugs, errors, or unexpected behavior - analysis only, no code changes
runInPlanMode: false
scope: project
---

Orchestrate a **read-only investigation** for the reported issue. DO NOT write or modify any code.

## Issue to Investigate

{{ARGUMENTS}}

## Investigation Workflow

### Phase 1: Initial Investigation

Use the Task tool to launch the **bug-investigator** agent with this prompt:

> Investigate the following issue: {{ARGUMENTS}}
>
> IMPORTANT: This is a READ-ONLY investigation. Do NOT write or modify any code.
>
> Provide a detailed investigation report including:
>
> - Root cause analysis with clear explanation
> - Evidence (logs, stack traces, configuration, code snippets you found)
> - Explanation of WHY the bug occurs (the mechanism)
> - Assessment: Is this a simple issue or does it need deeper analysis?

### Phase 2: Deep Investigation (if needed)

If the bug-investigator finds the root cause is unclear or involves complex interactions across multiple components, escalate to a deeper investigation by launching these agents **in parallel**:

- **Explore (git-history)**: Understand how the code evolved.
  Prompt: "MUST NOT suggest fixes or improvements. ONLY DO: run `git log --follow -p -- <affected_files>` and `git blame <file>` to show how the code changed over time. Return: commit messages, authors, and the diffs that introduced the relevant logic. No analysis — just historical facts."

- **Explore (repo-patterns)**: Find related patterns and architectural context.
  Prompt: "MUST NOT critique code quality or suggest changes. ONLY DO: find code in the repository that is structurally similar to <affected_area> — same data flow, same error pattern, same integration type. Return file:line refs and describe what each pattern does. No recommendations."

- **code-logic-explainer**: Trace through the execution flow and explain the mechanism

Then synthesize all findings into a comprehensive explanation.

### Decision Criteria for Deep Investigation

Escalate to deep investigation if:

- Root cause spans multiple services/components
- The bug involves race conditions or timing issues
- Historical context is needed to understand design decisions
- The code path is non-obvious or involves complex state
- Initial investigation raises more questions than answers

## Output Format

Present findings in this structure:

```markdown
# Investigation Report: [Brief Description]

## Summary
[2-3 sentence overview of the problem and root cause]

## Problem Description
- **Component(s)**: [affected services/files]
- **Severity**: [Critical/High/Medium/Low]
- **Impact**: [what users/systems experience]

## Root Cause Analysis
[Detailed explanation of WHY this happens, including:
- The mechanism causing the bug
- Code paths involved
- Any contributing factors]

## Evidence
- **Code**: [relevant code snippets with file paths]
- **Logs**: [relevant log entries if applicable]
- **Configuration**: [relevant config if applicable]

## How It Could Be Fixed
[High-level description of the fix approach - NO actual code changes]
- Complexity: Simple | Medium | Complex
- Files that would need changes: [list]
- Approach: [description]

## Related Context
[Any historical context, similar patterns, or architectural considerations]
```

## Agent Orchestration Map

```
                    /investigate
                         │
                         ▼
              ┌─────────────────────┐
              │   bug-investigator  │
              │   (read-only)       │
              └──────────┬──────────┘
                         │
            ┌────────────┴────────────┐
            │                         │
            ▼                         ▼
     Root Cause Clear          Root Cause Unclear
            │                         │
            ▼                         ▼
     Present Report          Deep Investigation (PARALLEL)
                             ┌────────┼────────┐
                             │        │        │
                             ▼        ▼        ▼
                    Explore     Explore  code-logic-
                  (git-history)(patterns) explainer
                             │        │        │
                             └────────┼────────┘
                                      │
                                      ▼
                            Synthesize & Explain
```

## Critical Rules

1. **NO CODE CHANGES** - This is investigation only
2. **EXPLAIN, DON'T FIX** - Focus on understanding and explaining
3. **SHOW EVIDENCE** - Always include code snippets, logs, traces you found
4. **BE THOROUGH** - If unclear, escalate to deep investigation
