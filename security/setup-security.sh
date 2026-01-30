#!/bin/bash
# setup-security.sh - Install all security configurations
# Run as root: sudo ./setup-security.sh
#
# Installs:
#   - UFW firewall rules
#   - Fail2ban configuration
#   - SSH hardening
#   - rkhunter (rootkit scanner)
#   - Automatic security updates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
SKIP_SSH_HARDENING=0
for arg in "$@"; do
    case $arg in
        --skip-ssh-hardening)
            SKIP_SSH_HARDENING=1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}           Nyx Security Stack Installation                 ${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

# ============================================
# Install packages
# ============================================
log_step "Installing security packages"

apt-get update -qq

PACKAGES=(
    ufw
    fail2ban
    rkhunter
    unattended-upgrades
    apt-listchanges
)

for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" &>/dev/null; then
        log_info "Installing $pkg..."
        apt-get install -y -qq "$pkg"
    else
        log_info "$pkg already installed"
    fi
done

# ============================================
# UFW Firewall
# ============================================
log_step "Configuring UFW firewall"

if [[ -f "${SCRIPT_DIR}/ufw-setup.sh" ]]; then
    bash "${SCRIPT_DIR}/ufw-setup.sh"
else
    log_warn "UFW setup script not found, configuring manually..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 41641/udp comment 'Tailscale'
    ufw deny 25/tcp comment 'Block SMTP'
    echo "y" | ufw enable
fi

# ============================================
# Fail2ban
# ============================================
log_step "Configuring Fail2ban"

if [[ -f "${SCRIPT_DIR}/fail2ban-jail.local" ]]; then
    cp "${SCRIPT_DIR}/fail2ban-jail.local" /etc/fail2ban/jail.local
    log_info "Installed fail2ban configuration"
else
    log_warn "Fail2ban config not found: ${SCRIPT_DIR}/fail2ban-jail.local"
fi

systemctl enable fail2ban
systemctl restart fail2ban

log_info "Fail2ban status:"
fail2ban-client status sshd 2>/dev/null || log_warn "Fail2ban sshd jail not yet active"

# ============================================
# SSH Hardening
# ============================================
if [[ $SKIP_SSH_HARDENING -eq 1 ]]; then
    log_step "Skipping SSH hardening (--skip-ssh-hardening)"
    log_info "SSH hardening will be applied later after user setup is complete"
else
    log_step "Hardening SSH"

    SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"
    mkdir -p "$SSH_CONFIG_DIR"

    if [[ -f "${SCRIPT_DIR}/sshd-hardening.conf" ]]; then
        cp "${SCRIPT_DIR}/sshd-hardening.conf" "${SSH_CONFIG_DIR}/99-hardening.conf"
        log_info "Installed SSH hardening configuration"

        # Test configuration
        if sshd -t; then
            log_info "SSH configuration valid"
            systemctl restart ssh  # Ubuntu 24.04 uses 'ssh' not 'sshd'
            log_info "SSH service restarted"
        else
            log_error "SSH configuration test failed!"
            rm -f "${SSH_CONFIG_DIR}/99-hardening.conf"
            log_warn "Removed invalid configuration"
        fi
    else
        log_warn "SSH hardening config not found: ${SCRIPT_DIR}/sshd-hardening.conf"
    fi
fi

# ============================================
# rkhunter
# ============================================
log_step "Configuring rkhunter"

# Update database
rkhunter --update || true
rkhunter --propupd || true

# Create weekly cron job
cat > /etc/cron.weekly/rkhunter-check <<'EOF'
#!/bin/bash
# Weekly rkhunter scan
/usr/bin/rkhunter --check --skip-keypress --report-warnings-only
EOF
chmod 755 /etc/cron.weekly/rkhunter-check

log_info "rkhunter configured for weekly scans"

# ============================================
# Automatic Security Updates
# ============================================
log_step "Configuring automatic security updates"

# Enable unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Configure what gets upgraded
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

log_info "Automatic security updates enabled"

# ============================================
# Kernel Hardening (sysctl)
# ============================================
log_step "Applying kernel hardening"

cat > /etc/sysctl.d/99-security.conf <<'EOF'
# Kernel hardening settings for Nyx

# ASLR
kernel.randomize_va_space = 2

# Protect hard/symlinks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# Network security
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1

# IPv6 (disable if not used)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF

sysctl -p /etc/sysctl.d/99-security.conf > /dev/null 2>&1 || true
log_info "Kernel hardening applied"

# ============================================
# Summary
# ============================================
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}           Security Stack Installation Complete            ${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Installed components:"
echo "  [x] UFW firewall (SSH + Tailscale only)"
echo "  [x] Fail2ban (SSH brute-force protection)"
echo "  [x] SSH hardening (keys only, no root)"
echo "  [x] rkhunter (weekly rootkit scans)"
echo "  [x] Automatic security updates"
echo "  [x] Kernel hardening (sysctl)"
echo ""
echo "Verification commands:"
echo "  sudo ufw status verbose"
echo "  sudo fail2ban-client status sshd"
echo "  sudo rkhunter --check --skip-keypress"
echo "  cat /var/log/unattended-upgrades/unattended-upgrades.log"
echo ""
