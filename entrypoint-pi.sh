#!/bin/bash
# Container entrypoint for pi-based autoframe agents.
#
# Auth:   host ~/.pi/agent/auth.json → /opt/host-pi-auth.json (read-only mount)
# Config: host ~/.pi/agent/          → /opt/host-pi/          (read-only mount)
# OAuth tokens are copied in at startup; the container runs one job then exits,
# so token refresh staying local is fine for --once test runs.

set -euo pipefail

PI_AGENT_DIR="${HOME}/.pi/agent"
WORKSPACE=/workspace/repo

# ── 0. Git credentials ───────────────────────────────────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global credential.helper store
    printf "https://oauth2:%s@github.com\n" "$GITHUB_TOKEN" > "${HOME}/.git-credentials"
    echo "[entrypoint] Git credentials configured via GITHUB_TOKEN"
fi

if [[ -d "${HOME}/.ssh" ]]; then
    ssh-keyscan -t ed25519 github.com >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
fi

# ── 1. Clone / update repo ───────────────────────────────────────────────────
if [[ -z "${GIT_REPO_URL:-}" ]]; then
    echo "[entrypoint] ERROR: GIT_REPO_URL is not set" >&2
    exit 1
fi

BASE_BRANCH="${GIT_BASE_BRANCH:-develop}"
mkdir -p /workspace

if [[ -d "$WORKSPACE/.git" ]]; then
    echo "[entrypoint] Repo already present — fetching latest"
    git -C "$WORKSPACE" fetch --all --prune 2>&1 || {
        git -C "$WORKSPACE" pack-refs --all
        git -C "$WORKSPACE" fetch --all --prune 2>&1 || true
    }
    git -C "$WORKSPACE" checkout "$BASE_BRANCH"
    git -C "$WORKSPACE" pull --ff-only
else
    echo "[entrypoint] Cloning ${GIT_REPO_URL} (branch: ${BASE_BRANCH})"
    git clone --branch "$BASE_BRANCH" "$GIT_REPO_URL" "$WORKSPACE"
fi

# Install autoframe agent scripts if not already present
if [[ ! -f "$WORKSPACE/scripts/autonomous-agent-process-pi.sh" ]]; then
    echo "[entrypoint] Installing autoframe pi scripts into workspace"
    mkdir -p "$WORKSPACE/scripts"
    cp /opt/autoframe/scripts/*.sh "$WORKSPACE/scripts/"
    chmod +x "$WORKSPACE/scripts/"*.sh
fi

# Install pi prompts into project if not present
mkdir -p "$WORKSPACE/.pi/prompts"
for f in /opt/autoframe/pi/prompts/*.md; do
    [[ -f "$f" ]] || continue
    dest="$WORKSPACE/.pi/prompts/$(basename "$f")"
    [[ -f "$dest" ]] || cp "$f" "$dest"
done

# Install .claude commands (still useful if anyone invokes claude directly)
mkdir -p "$WORKSPACE/.claude/commands"
for f in /opt/autoframe/commands/*.md; do
    dest="$WORKSPACE/.claude/commands/$(basename "$f")"
    [[ -f "$dest" ]] || cp "$f" "$dest"
done

echo "[entrypoint] Workspace ready at $WORKSPACE"

# ── 2. Bootstrap pi config ───────────────────────────────────────────────────
# Copy host pi config (extensions, agents, skills, prompts, themes, etc.) but
# NOT settings.json — the host settings lists packages that aren't pre-installed
# in the image and pi would try to npm install -g them as the non-root agent user.
mkdir -p "${PI_AGENT_DIR}"

if [[ -d "/opt/host-pi" ]]; then
    echo "[entrypoint] Copying host pi config from /opt/host-pi"
    cp -r /opt/host-pi/. "${PI_AGENT_DIR}/" 2>/dev/null || true
fi

# Always overwrite settings.json with the container-safe version that only
# references packages pre-installed in Dockerfile.pi (as root during build).
cat > "${PI_AGENT_DIR}/settings.json" <<'JSON'
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4-6",
  "defaultThinkingLevel": "high",
  "packages": [
    "npm:pi-subagents",
    "npm:@juicesharp/rpiv-todo",
    "npm:@aliou/pi-processes",
    "npm:@samfp/pi-memory",
    "npm:pi-agent-browser-native",
    "npm:pi-claude-oauth-adapter",
    "npm:pi-web-access"
  ],
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
JSON
echo "[entrypoint] Pi agent settings.json written (container-safe package list)"

# ── 3. Auth: OAuth token ─────────────────────────────────────────────────────
# auth.json holds the Anthropic OAuth refresh+access tokens.
# Priority: dedicated auth.json mount > copied from host pi dir > ANTHROPIC_API_KEY fallback.

if [[ -f "/opt/host-pi-auth.json" ]]; then
    cp /opt/host-pi-auth.json "${PI_AGENT_DIR}/auth.json"
    chmod 600 "${PI_AGENT_DIR}/auth.json"
    echo "[entrypoint] Pi auth: OAuth token from /opt/host-pi-auth.json"
elif [[ -f "${PI_AGENT_DIR}/auth.json" ]]; then
    chmod 600 "${PI_AGENT_DIR}/auth.json"
    echo "[entrypoint] Pi auth: OAuth token from host pi config copy"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "{\"anthropic\":{\"type\":\"api_key\",\"key\":\"${ANTHROPIC_API_KEY}\"}}" \
        > "${PI_AGENT_DIR}/auth.json"
    chmod 600 "${PI_AGENT_DIR}/auth.json"
    echo "[entrypoint] Pi auth: ANTHROPIC_API_KEY fallback"
else
    echo "[entrypoint] WARNING: no pi credentials found — agent will fail" >&2
fi

export PI_CODING_AGENT_DIR="${PI_AGENT_DIR}"

# ── 4. Model selection via AGENT_TIER env var (mirrors claude entrypoint behaviour)
TIER="${AGENT_TIER:-normal}"
case "$TIER" in
    advanced) PI_MODEL="claude-opus-4-7" ;;
    *)        PI_MODEL="claude-sonnet-4-6" ;;
esac
export PI_DEFAULT_MODEL="$PI_MODEL"
echo "[entrypoint] Tier: ${TIER} → model: ${PI_MODEL}"

# ── 5. Xvfb (needed for Chromium / agent-browser in Docker) ─────────────────
Xvfb :99 -screen 0 1280x900x24 -ac &
XVFB_PID=$!
export DISPLAY=:99
sleep 1

cleanup() { kill "$XVFB_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "[entrypoint] DISPLAY=:99 ready (Xvfb PID=$XVFB_PID)"

# ── 6. Run agent from workspace root ─────────────────────────────────────────
cd "$WORKSPACE"
exec "$@"
