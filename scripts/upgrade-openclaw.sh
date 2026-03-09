#!/bin/bash
# ABOUTME: Upgrades OpenClaw on Nyx server via SSH.
# ABOUTME: Stops the service, pulls latest code, rebuilds, reinstalls, and restarts.
#
# The built-in `openclaw update` command fails because the systemd service
# uses ProtectHome=read-only, making ~/openclaw-git read-only at runtime.
# This script runs the upgrade outside the service context.
#
# IMPORTANT: After checking out a new version, `npm run build` is required
# to regenerate dist/plugin-sdk/ files. Without this, plugins (telegram,
# device-pair, memory-core) fail to load due to missing module exports.
# The build requires pnpm (installed globally if missing).
#
# Usage:
#   ./scripts/upgrade-openclaw.sh              # Upgrade to latest (main)
#   ./scripts/upgrade-openclaw.sh --dry-run    # Show what would happen
#   ./scripts/upgrade-openclaw.sh --tag v2026.3.7 # Upgrade to specific tag

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NYX_HOST="nyx"
OPENCLAW_DIR="openclaw-git"
OPENCLAW_BIN=".local/share/npm-global/bin/openclaw"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

DRY_RUN=0
TARGET_TAG=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Upgrade OpenClaw on the Nyx server via SSH.

OPTIONS:
    --dry-run       Show current/available versions without upgrading
    --tag <tag>     Upgrade to a specific git tag (default: latest main)
    -h, --help      Show this help

EXAMPLES:
    $(basename "$0")                    # Upgrade to latest main
    $(basename "$0") --dry-run          # Check versions only
    $(basename "$0") --tag v2026.3.7    # Pin to specific release

NOTES:
    - Requires SSH access to nyx (via Tailscale)
    - Bot will be briefly unavailable during upgrade
    - Always prefer tagged releases over bleeding-edge main
    - The script runs 'npm run build' to regenerate plugin SDK files
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --tag)      TARGET_TAG="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Verify SSH connectivity
log_step "Checking SSH connectivity to $NYX_HOST..."
if ! ssh -o ConnectTimeout=5 "$NYX_HOST" "true" 2>/dev/null; then
    log_error "Cannot reach $NYX_HOST via SSH. Is Tailscale up?"
    exit 1
fi

# Get current version
log_step "Current OpenClaw version:"
CURRENT_VERSION=$(ssh "$NYX_HOST" ". ~/.nix-profile/etc/profile.d/nix.sh 2>/dev/null; ~/$OPENCLAW_BIN --version 2>/dev/null" || echo "unknown")
echo "  $CURRENT_VERSION"

# Check available version
log_step "Checking available version..."
AVAILABLE_INFO=$(ssh "$NYX_HOST" "cd ~/$OPENCLAW_DIR && git fetch --tags origin 2>/dev/null && git log HEAD..origin/main --oneline 2>/dev/null | wc -l" || echo "0")
echo "  Commits behind origin/main: $AVAILABLE_INFO"

# Show latest tags
log_step "Latest release tags:"
ssh "$NYX_HOST" "cd ~/$OPENCLAW_DIR && git tag --sort=-v:refname | grep -v beta | head -5" 2>/dev/null | while read -r tag; do
    echo "  $tag"
done

if [[ -n "$TARGET_TAG" ]]; then
    echo "  Target tag: $TARGET_TAG"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    log_info "Dry run complete — no changes made"
    exit 0
fi

# Confirm upgrade
echo ""
if [[ -n "$TARGET_TAG" ]]; then
    echo -e "${YELLOW}This will upgrade OpenClaw to tag $TARGET_TAG on $NYX_HOST.${NC}"
else
    echo -e "${YELLOW}This will upgrade OpenClaw to latest main on $NYX_HOST.${NC}"
fi
echo -e "${YELLOW}The bot will be briefly unavailable during the upgrade.${NC}"
read -r -p "Proceed? [y/N] " response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    log_info "Aborted"
    exit 0
fi

# Stop the service and kill any orphaned gateway processes
log_step "Stopping openclaw service..."
ssh "$NYX_HOST" "sudo systemctl stop openclaw"
ssh "$NYX_HOST" "pkill -9 -f 'openclaw-gatewa' 2>/dev/null || true"
sleep 2
log_info "Service stopped"

# Pull latest code, rebuild, and reinstall
log_step "Updating openclaw-git repository..."
ssh "$NYX_HOST" "bash -s" <<SCRIPT
set -euo pipefail

# Source Nix profile for npm/node/pnpm
if [[ -f "\$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    . "\$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export PATH="\$HOME/.local/share/npm-global/bin:\$PATH"

cd ~/$OPENCLAW_DIR

# Clean untracked changelog fragments that block git pull
echo "Cleaning untracked files..."
git clean -fd

# Fetch and update
git fetch --tags origin

if [[ -n "$TARGET_TAG" ]]; then
    echo "Checking out tag: $TARGET_TAG"
    git checkout "$TARGET_TAG"
else
    echo "Pulling latest main..."
    git checkout main
    git pull origin main
fi

# Ensure pnpm is available (required for build)
if ! command -v pnpm &>/dev/null; then
    echo "Installing pnpm..."
    npm install -g pnpm
fi

# Install dependencies with pnpm (required for build)
echo "Installing dependencies with pnpm..."
pnpm install

# Rebuild dist/ (critical: generates plugin-sdk module exports)
echo "Building dist/ (plugin-sdk, control-ui, etc.)..."
npm run build

# Reinstall globally
echo "Installing openclaw globally..."
npm install -g .

echo "Update complete"
SCRIPT

# Restart the service
log_step "Starting openclaw service..."
ssh "$NYX_HOST" "sudo systemctl start openclaw"

# Wait and verify
sleep 5
log_step "Verifying..."
NEW_VERSION=$(ssh "$NYX_HOST" ". ~/.nix-profile/etc/profile.d/nix.sh 2>/dev/null; ~/$OPENCLAW_BIN --version 2>/dev/null" || echo "unknown")
SERVICE_STATUS=$(ssh "$NYX_HOST" "systemctl is-active openclaw 2>/dev/null" || echo "unknown")

echo "  Version: $NEW_VERSION"
echo "  Service: $SERVICE_STATUS"

if [[ "$SERVICE_STATUS" == "active" ]]; then
    log_info "Upgrade successful: $CURRENT_VERSION -> $NEW_VERSION"
else
    log_warn "Service not yet active (may still be starting). Check with:"
    echo "  ssh $NYX_HOST 'sudo journalctl -u openclaw -n 50'"
    echo "  ssh $NYX_HOST 'systemctl is-active openclaw'"
    exit 1
fi
