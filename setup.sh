#!/usr/bin/env bash
# setup.sh — configure the autonomous agents for your project
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.auto-claude/.env"

# ── Colors ────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { echo -e "${CYAN}$*${RESET}"; }
ok()    { echo -e "${GREEN}✓ $*${RESET}"; }
warn()  { echo -e "${YELLOW}⚠  $*${RESET}"; }
error() { echo -e "${RED}✗ $*${RESET}"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Checking prerequisites...${RESET}"
echo ""

check_cmd() {
    local cmd="$1"
    local hint="$2"
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd found"
    else
        warn "$cmd not found — $hint"
    fi
}

check_cmd claude  "Install from: npm install -g @anthropic-ai/claude-code  then run: claude login"
check_cmd git     "Install from: https://git-scm.com"
check_cmd curl    "Usually pre-installed on macOS/Linux"
check_cmd python3 "Install from: https://python.org"

echo ""
if command -v wtp &>/dev/null; then
    ok "wtp (worktree helper) found"
else
    warn "wtp not found. Install from https://github.com/nicholasgasior/wtp or the scripts will fall back to plain git worktree commands."
fi

# ── Config ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Configuration${RESET}"
echo ""

mkdir -p "$SCRIPT_DIR/.auto-claude"

# Linear team key
echo -n "Enter your Linear team key (e.g. ENG, ACME): "
read -r TEAM_KEY
TEAM_KEY="${TEAM_KEY:-ENG}"

# Linear API key
echo -n "Enter your Linear API key: "
read -rs LINEAR_KEY
echo ""

# Write .auto-claude/.env
cat > "$ENV_FILE" << EOF
LINEAR_API_KEY=${LINEAR_KEY}
LINEAR_TEAM_KEY=${TEAM_KEY}
EOF

ok "Wrote config to .auto-claude/.env"

# ── Optional: copy to target repo ─────────────────────────────────────────────

echo ""
echo -n "Copy agent scripts to a target repo? Enter path (or press Enter to skip): "
read -r TARGET_REPO

if [[ -n "$TARGET_REPO" ]]; then
    TARGET_REPO="${TARGET_REPO/#\~/$HOME}"  # expand ~
    if [[ ! -d "$TARGET_REPO" ]]; then
        error "Directory not found: $TARGET_REPO"
    else
        mkdir -p "$TARGET_REPO/scripts"
        mkdir -p "$TARGET_REPO/.claude/commands"

        cp "$SCRIPT_DIR/scripts/"*.sh "$TARGET_REPO/scripts/"
        chmod +x "$TARGET_REPO/scripts/"*.sh
        cp "$SCRIPT_DIR/.claude/commands/"*.md "$TARGET_REPO/.claude/commands/"

        # Copy .env config if .auto-claude doesn't exist yet
        if [[ ! -f "$TARGET_REPO/.auto-claude/.env" ]]; then
            mkdir -p "$TARGET_REPO/.auto-claude"
            cp "$ENV_FILE" "$TARGET_REPO/.auto-claude/.env"
            ok "Wrote .auto-claude/.env to target repo"
        else
            info "Skipped .auto-claude/.env (already exists in target repo)"
        fi

        ok "Copied scripts and commands to: $TARGET_REPO"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo "Team key : ${TEAM_KEY}"
echo "Config   : .auto-claude/.env"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo "  1. Ensure the following workflow states exist in your Linear team:"
echo "     Todo, In Progress, In Review, Human Review, Merging, Done, Changes Required"
echo ""
echo "  2. Run each agent in a separate terminal from your project root:"
echo ""
echo -e "     ${CYAN}./scripts/autonomous-agent.sh${RESET}         # processes Todo + Changes Required"
echo -e "     ${CYAN}./scripts/autonomous-review-agent.sh${RESET}  # reviews In Review tickets"
echo -e "     ${CYAN}./scripts/autonomous-approve-agent.sh${RESET} # merges Merging tickets"
echo ""
echo "  3. Add a CLAUDE.md to your project root describing your stack and conventions."
echo "     The agents load it as context for every ticket."
echo ""
echo -e "${BOLD}To stale-lock cleanup (if agents crash mid-ticket):${RESET}"
echo "  rm -rf /tmp/agent-lock-${TEAM_KEY}-* /tmp/review-lock-${TEAM_KEY}-* /tmp/approve-lock-${TEAM_KEY}-*"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
