#!/bin/bash
# Container entrypoint for autoframe agents.
#
# On first start the container clones GIT_REPO_URL fresh into /workspace/repo,
# so it is completely isolated from the host filesystem. All branches and
# worktrees live inside the container; changes are pushed to the remote.
#
# Patches needed for the container environment:
#   • ~/.claude.json  — linear-server (stdio/API-key) + headless chrome-devtools
#   • git credentials — GITHUB_TOKEN → HTTPS auth, or mount ~/.ssh for SSH

set -euo pipefail

WORKSPACE=/workspace/repo

# ── 0. API routing ───────────────────────────────────────────────────────────
# Priority order:
#   1. CLAUDE_CODE_OAUTH_TOKEN — long-lived token from `claude setup-token`
#   2. ANTHROPIC_API_KEY       — direct Anthropic API key
#   3. OPENROUTER_API_KEY      — OpenRouter (routed through local proxy)

_start_openrouter_proxy() {
    OR_PROXY_TARGET="https://openrouter.ai" OR_PROXY_PORT="9090" \
        python3 /usr/local/bin/or-proxy.py &
    OR_PROXY_PID=$!
    sleep 1
    export ANTHROPIC_BASE_URL="http://127.0.0.1:9090/api"
    AUTH_MODE="openrouter"
    echo "[entrypoint] OpenRouter proxy started (PID=$OR_PROXY_PID) → ${ANTHROPIC_BASE_URL}"
}

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    # Claude Code reads this env var directly — no extra config needed.
    AUTH_MODE="oauth_token"
    echo "[entrypoint] Using CLAUDE_CODE_OAUTH_TOKEN (Claude subscription)"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    AUTH_MODE="apikey"
    echo "[entrypoint] Using Anthropic API key"
elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    export ANTHROPIC_API_KEY="$OPENROUTER_API_KEY"
    _start_openrouter_proxy
else
    echo "[entrypoint] WARNING: no credentials configured" >&2
    AUTH_MODE="none"
fi

# ── 1. Git credentials ───────────────────────────────────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global credential.helper store
    # Works for both github.com and GitHub Enterprise
    printf "https://oauth2:%s@github.com\n" "$GITHUB_TOKEN" > "${HOME}/.git-credentials"
    echo "[entrypoint] Git credentials configured via GITHUB_TOKEN"
fi

# SSH: if ~/.ssh is mounted from the host, trust GitHub's host key
if [[ -d "${HOME}/.ssh" ]]; then
    ssh-keyscan -t ed25519 github.com >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
fi

# ── 2. Clone / update repo ───────────────────────────────────────────────────
if [[ -z "${GIT_REPO_URL:-}" ]]; then
    echo "[entrypoint] ERROR: GIT_REPO_URL is not set" >&2
    exit 1
fi

BASE_BRANCH="${GIT_BASE_BRANCH:-develop}"
mkdir -p /workspace

if [[ -d "$WORKSPACE/.git" ]]; then
    echo "[entrypoint] Repo already present — fetching latest"
    git -C "$WORKSPACE" fetch --all --prune
    git -C "$WORKSPACE" checkout "$BASE_BRANCH"
    git -C "$WORKSPACE" pull --ff-only
else
    echo "[entrypoint] Cloning ${GIT_REPO_URL} (branch: ${BASE_BRANCH})"
    git clone --branch "$BASE_BRANCH" "$GIT_REPO_URL" "$WORKSPACE"
fi

# Install autoframe agent scripts if the repo doesn't already have them
# (i.e., setup.sh hasn't been run on this project yet)
if [[ ! -f "$WORKSPACE/scripts/autonomous-agent-process.sh" ]]; then
    echo "[entrypoint] Installing autoframe scripts into workspace"
    mkdir -p "$WORKSPACE/scripts"
    cp /opt/autoframe/scripts/*.sh "$WORKSPACE/scripts/"
    chmod +x "$WORKSPACE/scripts/"*.sh
fi

# Install autoframe Claude commands into project if not present
# (global ~/.claude/commands also works, but project-level takes precedence)
mkdir -p "$WORKSPACE/.claude/commands"
for f in /opt/autoframe/commands/*.md; do
    dest="$WORKSPACE/.claude/commands/$(basename "$f")"
    [[ -f "$dest" ]] || cp "$f" "$dest"
done

echo "[entrypoint] Workspace ready at $WORKSPACE"

# ── 3. Bootstrap ~/.claude from host config ──────────────────────────────────
# Host ~/.claude is staged at /opt/host-claude (read-only).
mkdir -p "${HOME}/.claude"
for _f in settings.json settings.local.json CLAUDE.md; do
    [[ -f "/opt/host-claude/$_f" ]] && cp "/opt/host-claude/$_f" "${HOME}/.claude/$_f"
done
for _d in memory skills agents plugins commands; do
    [[ -d "/opt/host-claude/$_d" ]] && cp -r "/opt/host-claude/$_d" "${HOME}/.claude/$_d"
done
# Always blank credentials.json — Claude Code reads the key from ANTHROPIC_API_KEY.
echo '{"version":1}' > "${HOME}/.claude/credentials.json"
echo "[entrypoint] ~/.claude bootstrapped"

# ── 4. Patch ~/.claude.json ──────────────────────────────────────────────────
cp /opt/host-claude.json "${HOME}/.claude.json"

python3 - <<'PYEOF'
import json, os

claude_json = os.path.join(os.environ['HOME'], '.claude.json')
with open(claude_json) as f:
    config = json.load(f)

config.setdefault('mcpServers', {})

config['mcpServers']['linear-server'] = {
    'type': 'stdio',
    'command': 'node',
    'args': ['/opt/linear-mcp/server.js'],
    'env': {'LINEAR_API_KEY': os.environ.get('LINEAR_API_KEY', '')},
}

config['mcpServers']['chrome-devtools'] = {
    'type': 'stdio',
    'command': 'npx',
    'args': [
        'chrome-devtools-mcp@latest',
        '--headless',
        '--chromeArg=--no-sandbox',
        '--chromeArg=--disable-dev-shm-usage',
        '--chromeArg=--disable-gpu',
        '-e', '/usr/bin/chromium',
    ],
    'env': {},
}

auth_mode = os.environ.get('AUTH_MODE', 'apikey')

# Always strip OAuth account — auth goes through ANTHROPIC_API_KEY env var.
config.pop('oauthAccount', None)

if auth_mode == 'openrouter':
    # Disable the advisor tool (type: advisor_20260301) — OpenRouter rejects it.
    # The proxy strips it at the wire level too, but defence-in-depth.
    if 'cachedGrowthBookFeatures' in config:
        config['cachedGrowthBookFeatures']['tengu_amber_sentinel'] = False
    if 'cachedStatsigGates' in config:
        config['cachedStatsigGates']['tengu_amber_sentinel'] = False

# oauth_token mode: Claude Code reads CLAUDE_CODE_OAUTH_TOKEN directly.
# No ANTHROPIC_API_KEY or base URL override needed.

for proj in config.get('projects', {}).values():
    disabled = proj.get('disabledMcpServers', [])
    if 'linear-server' in disabled:
        proj['disabledMcpServers'] = [s for s in disabled if s != 'linear-server']

with open(claude_json, 'w') as f:
    json.dump(config, f, indent=2)

print('[entrypoint] ~/.claude.json patched')
PYEOF

# ── 4b. Model selection & logging ────────────────────────────────────────────
python3 - <<PYEOF2
import json, os

settings_path = os.path.join(os.environ['HOME'], '.claude', 'settings.json')
try:
    with open(settings_path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}

auth_mode = os.environ.get('AUTH_MODE', '')
tier      = os.environ.get('AGENT_TIER', 'normal')  # 'normal' | 'advanced'

ANTHROPIC_MODELS = {
    'normal':   'claude-sonnet-4-6',
    'advanced': 'claude-opus-4-7',
}
OR_MODELS = {
    'normal':   os.environ.get('OR_MODEL_NORMAL', ''),
    'advanced': os.environ.get('OR_MODEL_ADVANCED', ''),
}

if auth_mode in ('apikey', 'oauth_token'):
    model = ANTHROPIC_MODELS[tier]
    settings['model'] = model
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
elif auth_mode == 'openrouter':
    model = OR_MODELS[tier]
    if model:
        settings['model'] = model
        with open(settings_path, 'w') as f:
            json.dump(settings, f, indent=2)
    else:
        model = settings.get('model', '(not set)')

active_model = settings.get('model', '(subscription default)')

if auth_mode == 'oauth_token':
    provider = 'Anthropic (Claude subscription)'
elif auth_mode == 'apikey':
    provider = 'Anthropic (API key)'
elif auth_mode == 'openrouter':
    provider = 'OpenRouter'
else:
    provider = 'unknown'

print(f"[entrypoint] Provider : {provider}")
print(f"[entrypoint] Tier     : {tier}")
print(f"[entrypoint] Model    : {active_model}")
PYEOF2

# ── 5. Xvfb ─────────────────────────────────────────────────────────────────
Xvfb :99 -screen 0 1280x900x24 -ac &
XVFB_PID=$!
export DISPLAY=:99
sleep 1

cleanup() {
    kill "$XVFB_PID" 2>/dev/null || true
    kill "${OR_PROXY_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[entrypoint] DISPLAY=:99 ready (Xvfb PID=$XVFB_PID)"

# ── 6. Run agent from workspace root ─────────────────────────────────────────
cd "$WORKSPACE"
exec "$@"
