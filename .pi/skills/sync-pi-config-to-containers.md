# sync-pi-config-to-containers

Sync local `~/.pi/agent` config to autoframe container agents. Updates Dockerfile.pi packages and entrypoint-pi.sh filter, then rebuilds images.

## When to Use

When local Pi config has changed (`~/.pi/agent/settings.json`, extensions, models, etc.) and those changes should be reflected in the autoframe container agents.

## Procedure

### 1. Gather current state

Read these files to understand what changed:
- `~/.pi/agent/settings.json` — packages, provider, model, theme, compaction, etc.
- `~/.pi/agent/models.json` — model overrides
- `~/.pi/agent/extensions/` — extension configs
- Project files:
  - `Dockerfile.pi` — currently pre-installed packages
  - `entrypoint-pi.sh` — settings.json generation and filter logic

### 2. Identify sync targets

Compare local config to container config. The sync covers:

**Packages** (`Dockerfile.pi` + `entrypoint-pi.sh` fallback):
- Map each package in `settings.json.packages` to a global npm install in Dockerfile.pi
- Packages to EXCLUDE (autonomous agents): `ask-user-question`, `pi-guardrails`
- Update the npm install list in Dockerfile.pi
- Update the fallback settings.json in entrypoint-pi.sh

**Provider & model** (`entrypoint-pi.sh`):
- Containers always use `anthropic` provider (not `opencode-go`, `openrouter`, etc.)
- Default model: `claude-sonnet-4-6` (overridden by AGENT_TIER at runtime)
- These are set in the Python transform script in entrypoint-pi.sh

**Other settings** (`entrypoint-pi.sh`):
- `theme`, `thinkingLevel`, `enabledModels`, `hideThinkingBlock`, `compaction` — flow through from host config automatically (no code changes needed)

**Extensions configs** (`~/.pi/agent/extensions/`):
- These are copied from the host mount `/opt/host-pi` at container startup
- No code changes needed unless an extension is added that would block autonomous agents → add to filter list

### 3. Update Dockerfile.pi

Edit the `npm install -g` block to match the desired package list. Package names from settings.json strip the `npm:` prefix:
```
"npm:pi-teams" → pi-teams
"npm:@juicesharp/rpiv-advisor" → @juicesharp/rpiv-advisor
```

### 4. Update entrypoint-pi.sh

Two places to update:

a) **Python filter** — the list comprehension that strips packages:
```python
cfg['packages'] = [p for p in cfg.get('packages', []) if 'ask-user-question' not in p and 'pi-guardrails' not in p]
```
Add any new package names that should be excluded.

b) **Fallback settings.json** — used if host config mount fails. Mirror the package list from Dockerfile.pi with `npm:` prefixes.

### 5. Rebuild images

```bash
cd /Users/chuanbai/code/autoframe
docker compose --profile process-pi build --no-cache process-pi
```

For all PI services at once:
```bash
docker compose --profile all-pi build --no-cache
```

### 6. Verify

Check installed packages in the new image:
```bash
docker run --rm --entrypoint bash autoframe-process-pi:latest -c \
  "npm list -g --depth=0 2>/dev/null | grep -E 'pi-|context-mode|rpiv-'"
```

Verify entrypoint filters:
```bash
docker run --rm --entrypoint bash autoframe-process-pi:latest -c \
  "grep 'packages.*filter\|ask-user-question\|pi-guardrails' /usr/local/bin/entrypoint-pi.sh"
```

## Key Files

| File | Purpose |
|---|---|
| `~/.pi/agent/settings.json` | Source of truth (host) |
| `Dockerfile.pi` | Pre-installed npm packages |
| `entrypoint-pi.sh` | Runtime config generation + filters |
| `docker-compose.yml` | Volume mounts, service definitions |

## Exclusion Rules

These packages are ALWAYS excluded from containers (autonomous agents must not block):
- `@juicesharp/rpiv-ask-user-question` — interactive user prompts
- `@aliou/pi-guardrails` — confirmation/approval guardrails

If new extensions are added to host that could block, add them to the filter list.

## Provider/Model Constraints

- Provider is always `anthropic` in containers (host may use `opencode-go`, `openrouter`, etc.)
- Default model is `claude-sonnet-4-6` (AGENT_TIER=normal) or `claude-opus-4-7` (AGENT_TIER=advanced)
- These are hardcoded in the Python transform — not synced from host
