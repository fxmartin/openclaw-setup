#!/usr/bin/env bash
# Update Nix flake inputs and apply new configuration
# Run this to get latest package versions while maintaining reproducibility
#
# Usage: nix-update.sh [--dry-run]

# === ENVIRONMENT BOOTSTRAP (before strict mode) ===
# Ensure critical vars exist for cron environments
export HOME="${HOME:-/home/fx}"
export USER="${USER:-fx}"
export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Source Nix profile if it exists
if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nix-profile/etc/profile.d/nix.sh" 2>/dev/null || true
fi

# === NOW enable strict mode ===
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    log_warn "Dry run mode - no changes will be applied"
fi

# Verify Nix is available
if ! command -v nix &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Nix not found. Is it installed?"
    echo -e "${RED}[DEBUG]${NC} PATH=$PATH"
    echo -e "${RED}[DEBUG]${NC} HOME=$HOME"
    exit 1
fi

NIX_CONFIG_DIR="${HOME}/nix-config"

if [[ ! -d "${NIX_CONFIG_DIR}" ]]; then
    echo -e "${RED}[ERROR]${NC} Nix config directory not found: ${NIX_CONFIG_DIR}"
    exit 1
fi

cd "${NIX_CONFIG_DIR}"

# Show current generation before update
log_step "Current home-manager generation:"
home-manager generations | head -5
echo ""

# Update flake.lock
log_step "Updating flake inputs (nixpkgs, home-manager)..."
if [[ "${DRY_RUN}" == true ]]; then
    log_info "Would run: nix flake update"
else
    nix flake update
fi

# Show what changed in the lock file
log_step "Changes to flake.lock:"
git -C "${NIX_CONFIG_DIR}" diff --stat flake.lock 2>/dev/null || echo "(not tracked by git)"
echo ""

# Apply new configuration
if [[ "${DRY_RUN}" == true ]]; then
    log_info "Would apply: home-manager switch --flake .#fx"
else
    log_step "Applying updated configuration..."
    home-manager switch --flake .#fx

    log_info "Update complete!"
    echo ""
    log_step "New generation:"
    home-manager generations | head -3
fi

echo ""
echo "To rollback if something breaks:"
echo "  home-manager generations"
echo "  home-manager switch --generation <N>"
