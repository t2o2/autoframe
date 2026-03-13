#!/usr/bin/env bash
# setup.sh — configure the autonomous agents for your project
set -uo pipefail

TMP_DIR="$(mktemp -d)"
ENV_FILE="$TMP_DIR/.env"
trap 'rm -rf "$TMP_DIR"' EXIT

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

# Linear team key
echo -n "Enter your Linear team key (e.g. ENG, ACME): "
read -r TEAM_KEY
TEAM_KEY="${TEAM_KEY:-ENG}"

# Linear API key
echo -n "Enter your Linear API key: "
read -rs LINEAR_KEY
echo ""

# Write .env
cat > "$ENV_FILE" << EOF
LINEAR_API_KEY=${LINEAR_KEY}
LINEAR_TEAM_KEY=${TEAM_KEY}
EOF

ok "Wrote config to .env"

# ── Download scripts to target repo ───────────────────────────────────────────

REPO_RAW="https://raw.githubusercontent.com/t2o2/autoframe/master"

SCRIPTS=(
    "scripts/autonomous-agent-research.sh"
    "scripts/autonomous-agent-plan.sh"
    "scripts/autonomous-agent-process.sh"
    "scripts/autonomous-agent-review.sh"
    "scripts/autonomous-agent-approve.sh"
    "scripts/ask-human.sh"
)

COMMANDS=(
    ".claude/commands/ticket-research.md"
    ".claude/commands/ticket-plan.md"
    ".claude/commands/ticket-process.md"
    ".claude/commands/ticket-review.md"
    ".claude/commands/ticket-approve.md"
)

echo ""
echo -e "${BOLD}Install scripts${RESET}"
echo ""
echo -e "  Default destination: ${CYAN}$(pwd)${RESET}"
echo -n "  Press Enter to confirm, type a different path, or 'n' to skip: "
read -r TARGET_REPO_INPUT

if [[ "$TARGET_REPO_INPUT" == "n" || "$TARGET_REPO_INPUT" == "N" ]]; then
    info "Skipping script install."
    TARGET_REPO=""
elif [[ -n "$TARGET_REPO_INPUT" ]]; then
    TARGET_REPO="${TARGET_REPO_INPUT/#\~/$HOME}"
else
    TARGET_REPO="$(pwd)"
fi

if [[ -n "$TARGET_REPO" ]]; then
    if [[ ! -d "$TARGET_REPO" ]]; then
        error "Directory not found: $TARGET_REPO"
    else
        mkdir -p "$TARGET_REPO/scripts"
        mkdir -p "$TARGET_REPO/.claude/commands"

        for file in "${SCRIPTS[@]}"; do
            curl -fsSL "$REPO_RAW/$file" -o "$TARGET_REPO/$file"
            chmod +x "$TARGET_REPO/$file"
        done

        for file in "${COMMANDS[@]}"; do
            curl -fsSL "$REPO_RAW/$file" -o "$TARGET_REPO/$file"
        done

        # Write .env config if .auto-claude doesn't exist yet
        if [[ ! -f "$TARGET_REPO/.env" ]]; then
            mkdir -p "$TARGET_REPO/.auto-claude"
            cp "$ENV_FILE" "$TARGET_REPO/.env"
            ok "Wrote .env to $(basename "$TARGET_REPO")"
        else
            info "Skipped .env (already exists)"
        fi

        ok "Downloaded scripts and commands to: $TARGET_REPO"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo "Team key : ${TEAM_KEY}"
echo "Config   : .env"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo "  1. Ensure the following workflow states exist in your Linear team:"
echo "     Todo, Research, Research Pending Approval, Planning, Plan Pending Approval,"
echo "     Plan Approved, In Progress, In Review, Human Review, Merging, Done, Changes Required"
echo ""
echo "  2. Run each agent in a separate terminal from your project root:"
echo ""
echo -e "     ${CYAN}./scripts/autonomous-agent-research.sh${RESET}  # researches Todo tickets"
echo -e "     ${CYAN}./scripts/autonomous-agent-plan.sh${RESET}  # plans Planning tickets"
echo -e "     ${CYAN}./scripts/autonomous-agent-process.sh${RESET}           # implements Plan Approved + Changes Required"
echo -e "     ${CYAN}./scripts/autonomous-agent-review.sh${RESET}    # reviews In Review tickets"
echo -e "     ${CYAN}./scripts/autonomous-agent-approve.sh${RESET}   # merges Merging tickets"
echo ""
echo "  3. Add a CLAUDE.md to your project root describing your stack and conventions."
echo "     The agents load it as context for every ticket."
echo ""
echo -e "${BOLD}To stale-lock cleanup (if agents crash mid-ticket):${RESET}"
echo "  rm -rf /tmp/research-lock-* /tmp/plan-lock-* /tmp/process-lock-* /tmp/review-lock-* /tmp/approve-lock-*"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
