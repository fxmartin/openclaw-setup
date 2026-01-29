#!/bin/bash
# ufw-setup.sh - Configure UFW firewall for Nyx server
# Run as root: sudo ./ufw-setup.sh
#
# Opens:
#   - SSH (22/tcp) - Remote access
#   - Tailscale (41641/udp) - VPN mesh network
#
# Blocks all other incoming traffic by default.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# Install UFW if not present
if ! command -v ufw &> /dev/null; then
    log_info "Installing UFW..."
    apt-get update -qq
    apt-get install -y -qq ufw
fi

log_info "Configuring UFW firewall..."

# Reset to defaults (non-interactive)
echo "y" | ufw reset > /dev/null 2>&1 || true

# Default policies
log_info "Setting default policies (deny incoming, allow outgoing)"
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (critical - don't lock yourself out!)
log_info "Allowing SSH (22/tcp)"
ufw allow 22/tcp comment 'SSH'

# Allow Tailscale
log_info "Allowing Tailscale (41641/udp)"
ufw allow 41641/udp comment 'Tailscale'

# Block SMTP (prevent abuse)
log_info "Blocking SMTP (25/tcp)"
ufw deny 25/tcp comment 'Block SMTP'

# Enable UFW (non-interactive)
log_info "Enabling UFW..."
echo "y" | ufw enable

# Show status
echo ""
log_info "Firewall status:"
ufw status verbose

echo ""
log_info "UFW configuration complete!"
echo ""
echo "Active rules:"
echo "  - SSH (22/tcp): ALLOW"
echo "  - Tailscale (41641/udp): ALLOW"
echo "  - SMTP (25/tcp): DENY"
echo "  - All other incoming: DENY"
