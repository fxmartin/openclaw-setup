#!/usr/bin/env bash
# Install Nix single-user with flakes enabled
# This script is idempotent and safe to re-run
#
# Usage: nyx-install-nix.sh [username]
#        Default username: fx

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

TARGET_USER="${1:-fx}"
TARGET_HOME="/home/${TARGET_USER}"

# Verify user exists
if ! id "${TARGET_USER}" &>/dev/null; then
    log_error "User ${TARGET_USER} does not exist"
    exit 1
fi

# Check if Nix is already installed
if command -v nix &>/dev/null; then
    log_info "Nix already installed: $(nix --version)"
else
    log_info "Installing Nix (single-user mode)..."

    # Download and run Nix installer as target user
    # Using --no-daemon for single-user installation (simpler, no systemd service)
    su - "${TARGET_USER}" -c 'curl -L https://nixos.org/nix/install | sh -s -- --no-daemon'

    log_info "Nix installation completed"
fi

# Configure flakes (experimental features)
NIX_CONF_DIR="${TARGET_HOME}/.config/nix"
NIX_CONF_FILE="${NIX_CONF_DIR}/nix.conf"

log_info "Configuring Nix flakes..."
mkdir -p "${NIX_CONF_DIR}"
cat > "${NIX_CONF_FILE}" << 'EOF'
# Enable flakes and nix-command for modern Nix usage
experimental-features = nix-command flakes

# Optimize storage
auto-optimise-store = true

# Keep build logs for debugging
keep-build-log = true
EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${NIX_CONF_DIR}"
log_info "Flakes configuration written to ${NIX_CONF_FILE}"

# Source Nix profile and verify installation
log_info "Verifying Nix installation..."
NIX_PROFILE="${TARGET_HOME}/.nix-profile/etc/profile.d/nix.sh"

if [[ -f "${NIX_PROFILE}" ]]; then
    # shellcheck source=/dev/null
    su - "${TARGET_USER}" -c ". ${NIX_PROFILE} && nix --version"
    log_info "Nix successfully configured with flakes support"
else
    log_error "Nix profile not found at ${NIX_PROFILE}"
    exit 1
fi

# Add Nix to shell profile if not already present
BASHRC="${TARGET_HOME}/.bashrc"
NIX_SOURCE_LINE='. "$HOME/.nix-profile/etc/profile.d/nix.sh"'

if ! grep -q 'nix.sh' "${BASHRC}" 2>/dev/null; then
    log_info "Adding Nix to ${BASHRC}"
    cat >> "${BASHRC}" << 'EOF'

# Nix package manager
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
EOF
    chown "${TARGET_USER}:${TARGET_USER}" "${BASHRC}"
fi

log_info "Nix single-user installation complete for user: ${TARGET_USER}"
echo ""
echo "Next steps:"
echo "  1. Copy Nix flake configuration to ~/nix-config/"
echo "  2. Run: home-manager switch --flake ~/nix-config#fx"
echo "  3. Log out and back in to refresh PATH"
