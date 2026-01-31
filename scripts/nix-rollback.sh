#!/usr/bin/env bash
# Rollback to a previous home-manager generation
# Useful when a package update causes issues
#
# Usage: nix-rollback.sh [generation-number]
#        If no generation specified, shows list and prompts

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

# Ensure Nix is available
if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

if ! command -v home-manager &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} home-manager not found. Is Nix configured properly?"
    exit 1
fi

# Show available generations
log_step "Available generations:"
echo ""
home-manager generations
echo ""

# Get current generation
CURRENT_GEN=$(home-manager generations | head -1 | awk '{print $5}')
log_info "Current generation: ${CURRENT_GEN}"
echo ""

# Get target generation
if [[ -n "${1:-}" ]]; then
    TARGET_GEN="$1"
else
    read -r -p "Enter generation number to rollback to (or 'q' to quit): " TARGET_GEN
    if [[ "${TARGET_GEN}" == "q" ]]; then
        log_info "Rollback cancelled"
        exit 0
    fi
fi

# Validate generation number
if ! [[ "${TARGET_GEN}" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[ERROR]${NC} Invalid generation number: ${TARGET_GEN}"
    exit 1
fi

if [[ "${TARGET_GEN}" == "${CURRENT_GEN}" ]]; then
    log_warn "Already at generation ${TARGET_GEN}, nothing to do"
    exit 0
fi

# Confirm rollback
echo ""
log_warn "This will switch from generation ${CURRENT_GEN} to ${TARGET_GEN}"
read -r -p "Continue? [y/N] " confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    log_info "Rollback cancelled"
    exit 0
fi

# Perform rollback
log_step "Rolling back to generation ${TARGET_GEN}..."
home-manager switch --generation "${TARGET_GEN}"

log_info "Rollback complete!"
echo ""
log_step "Current state:"
home-manager generations | head -3
echo ""
echo "To return to the latest: home-manager switch --flake ~/nix-config#fx"
