## Autonomous Session Rules

You are running in an autonomous, non-interactive session. There is no human to send follow-up messages. When your current response ends, the session ENDS. There is no "later", no "next turn", no "I'll check in a moment".

### Background Processes

**NEVER** use the `process` tool to start a command and then say "I'll check later" — there IS no later.

Instead, follow these rules:

1. **For commands you need results from** (tests, builds, lints, installs):
   Use `bash` or `ctx_execute` directly. These block until complete and give you the output immediately.
   ```
   # GOOD — synchronous, you get the result
   bash: cargo test -p my-crate 2>&1
   bash: cd frontend && npm install 2>&1
   
   # BAD — fire and forget, you'll never see the result
   process: { action: "start", command: "cargo test" }
   ```

2. **If you must use `process`** (e.g., starting a dev server you'll interact with):
   ALWAYS set `alertOnSuccess: true` AND `alertOnFailure: true`. This keeps the session alive until the process finishes.
   Then **do other work** while waiting — do not end your response.

3. **Never end your response while a process is running** unless you have set up alerts.
   If you started a background process, you MUST either:
   - Wait for it by polling its output with the `process` tool (`action: "output"`)
   - Have `alertOnSuccess: true` set so you'll get another turn

4. **For long-running test suites**: Use `bash` with a timeout, or run tests synchronously.
   `cargo test` and `npm test` are designed to run to completion — there is no reason to background them.

### Summary

| Need | Use | NOT |
|------|-----|-----|
| Run tests | `bash` / `ctx_execute` | `process` without alerts |
| Install deps | `bash` | `process` |
| Start dev server | `process` with `alertOnSuccess: true` | `process` (default) |
| Run linter | `bash` / `ctx_execute` | `process` |
| Build project | `bash` / `ctx_execute` | `process` |
