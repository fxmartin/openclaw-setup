#!/usr/bin/env bash
# nyx-provision.sh - Automated Nyx server provisioning on Hetzner
#
# Usage:
#   ./nyx-provision.sh --secrets-bundle /path/to/bundle.tar.gz.age
#   ./nyx-provision.sh --secrets-bundle /path/to/bundle.tar.gz.age --server-name nyx2
#   ./nyx-provision.sh --existing-server nyx --secrets-bundle /path/to/bundle.tar.gz.age
#
# Prerequisites:
#   - hcloud CLI installed and authenticated
#   - Secrets bundle from 1Password
#   - SSH key configured in Hetzner Cloud

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/lib/logging.sh"

# ============================================
# Configuration
# ============================================

# Server settings
SERVER_NAME="nyx"
SERVER_TYPE="cx22"
SERVER_IMAGE="ubuntu-24.04"
SERVER_LOCATION="nbg1"
SSH_KEY_NAME="default"

# Target user
TARGET_USER="fx"
TARGET_HOME="/home/${TARGET_USER}"

# Secrets bundle
SECRETS_BUNDLE=""

# Existing server (skip Hetzner creation)
EXISTING_SERVER=""

# Dry run mode
DRY_RUN=0

# Skip specific phases
SKIP_HETZNER=0
SKIP_SECRETS=0
SKIP_SOFTWARE=0
SKIP_WORKSPACE=0
SKIP_TAILSCALE=0

# ============================================
# Usage
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Provision a new Nyx server on Hetzner Cloud.

OPTIONS:
    -b, --secrets-bundle FILE   Secrets bundle file (required)
    -n, --server-name NAME      Server name (default: nyx)
    -t, --server-type TYPE      Server type (default: cx22)
    -l, --location LOCATION     Server location (default: nbg1)
    -e, --existing-server HOST  Provision existing server (skip Hetzner creation)
    --ssh-key NAME              SSH key name in Hetzner (default: default)
    --dry-run                   Show what would be done
    --skip-secrets              Skip secrets import
    --skip-software             Skip software installation
    --skip-workspace            Skip Dropbox workspace restore
    --skip-tailscale            Skip Tailscale setup
    -h, --help                  Show this help message

EXAMPLES:
    # Full provisioning (create new server)
    ./nyx-provision.sh --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age

    # Provision existing server
    ./nyx-provision.sh --existing-server nyx.example.com --secrets-bundle ~/bundle.tar.gz.age

    # Create server with custom name
    ./nyx-provision.sh --secrets-bundle ~/bundle.tar.gz.age --server-name nyx-prod
EOF
}

# ============================================
# Argument Parsing
# ============================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--secrets-bundle)
                SECRETS_BUNDLE="$2"
                shift 2
                ;;
            -n|--server-name)
                SERVER_NAME="$2"
                shift 2
                ;;
            -t|--server-type)
                SERVER_TYPE="$2"
                shift 2
                ;;
            -l|--location)
                SERVER_LOCATION="$2"
                shift 2
                ;;
            -e|--existing-server)
                EXISTING_SERVER="$2"
                SKIP_HETZNER=1
                shift 2
                ;;
            --ssh-key)
                SSH_KEY_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --skip-secrets)
                SKIP_SECRETS=1
                shift
                ;;
            --skip-software)
                SKIP_SOFTWARE=1
                shift
                ;;
            --skip-workspace)
                SKIP_WORKSPACE=1
                shift
                ;;
            --skip-tailscale)
                SKIP_TAILSCALE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate required args
    if [[ -z "$SECRETS_BUNDLE" ]] && [[ $SKIP_SECRETS -eq 0 ]]; then
        log_error "Secrets bundle is required (use --secrets-bundle)"
        usage
        exit 1
    fi

    if [[ -n "$SECRETS_BUNDLE" ]] && [[ ! -f "$SECRETS_BUNDLE" ]]; then
        log_fatal "Secrets bundle not found: $SECRETS_BUNDLE"
    fi
}

# ============================================
# Prerequisites Check
# ============================================

check_prerequisites() {
    log_step "Checking prerequisites"

    # Check hcloud CLI (unless using existing server)
    if [[ $SKIP_HETZNER -eq 0 ]]; then
        require_command hcloud
        log_substep "hcloud CLI available"

        # Verify hcloud is authenticated
        if ! hcloud context active &>/dev/null; then
            log_fatal "hcloud not authenticated. Run: hcloud context create nyx"
        fi
        log_substep "hcloud authenticated"
    fi

    # Check SSH
    require_command ssh
    require_command scp

    # Check SSH key exists
    if [[ ! -f "$HOME/.ssh/id_ed25519" ]] && [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
        log_warn "No SSH key found. You may need to configure SSH access manually."
    fi

    log_success "Prerequisites check passed"
}

# ============================================
# Phase 1: Hetzner Server Creation
# ============================================

create_hetzner_server() {
    if [[ $SKIP_HETZNER -eq 1 ]]; then
        log_step "Skipping Hetzner server creation (using existing server)"
        return 0
    fi

    log_step "Creating Hetzner Cloud server"

    # Check if server already exists
    if hcloud server describe "$SERVER_NAME" &>/dev/null; then
        log_warn "Server '$SERVER_NAME' already exists"
        if ! confirm "Delete and recreate?"; then
            log_info "Using existing server"
            SKIP_HETZNER=1
            return 0
        fi

        log_substep "Deleting existing server"
        hcloud server delete "$SERVER_NAME" --poll-interval 2s
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would create server:"
        log_info "  Name: $SERVER_NAME"
        log_info "  Type: $SERVER_TYPE"
        log_info "  Image: $SERVER_IMAGE"
        log_info "  Location: $SERVER_LOCATION"
        log_info "  SSH Key: $SSH_KEY_NAME"
        return 0
    fi

    log_substep "Creating $SERVER_TYPE server in $SERVER_LOCATION"

    local server_output
    server_output=$(hcloud server create \
        --name "$SERVER_NAME" \
        --type "$SERVER_TYPE" \
        --image "$SERVER_IMAGE" \
        --location "$SERVER_LOCATION" \
        --ssh-key "$SSH_KEY_NAME" \
        --poll-interval 2s \
        2>&1)

    log_debug "$server_output"

    # Get server IP
    SERVER_IP=$(hcloud server ip "$SERVER_NAME")
    log_success "Server created: $SERVER_NAME ($SERVER_IP)"

    # Wait for SSH to be ready
    log_substep "Waiting for SSH to be ready"
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
            "root@${SERVER_IP}" "echo ready" &>/dev/null; then
            log_success "SSH is ready"
            break
        fi
        ((attempt++))
        sleep 5
    done

    if [[ $attempt -ge $max_attempts ]]; then
        log_fatal "Timeout waiting for SSH"
    fi
}

# ============================================
# Remote Execution Helper
# ============================================

remote_exec() {
    local host="${EXISTING_SERVER:-root@${SERVER_IP}}"
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "$host" "$@"
}

remote_exec_script() {
    local script="$1"
    local host="${EXISTING_SERVER:-root@${SERVER_IP}}"
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "$host" "bash -s" < "$script"
}

remote_copy() {
    local src="$1"
    local dest="$2"
    local host="${EXISTING_SERVER:-root@${SERVER_IP}}"
    scp -o StrictHostKeyChecking=no "$src" "${host}:${dest}"
}

# ============================================
# Phase 2: Base Configuration
# ============================================

configure_base() {
    log_step "Configuring base system"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would configure:"
        log_info "  - Create user: $TARGET_USER"
        log_info "  - Set hostname: $SERVER_NAME"
        log_info "  - Configure SSH keys"
        return 0
    fi

    remote_exec "bash -s" <<SCRIPT
set -e

# Update system
echo "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# Set hostname
hostnamectl set-hostname "$SERVER_NAME"

# Create user if not exists
if ! id "$TARGET_USER" &>/dev/null; then
    echo "Creating user $TARGET_USER..."
    useradd -m -s /bin/bash "$TARGET_USER"
    usermod -aG sudo "$TARGET_USER"

    # Copy SSH keys from root
    mkdir -p "$TARGET_HOME/.ssh"
    cp /root/.ssh/authorized_keys "$TARGET_HOME/.ssh/"
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh"
    chmod 700 "$TARGET_HOME/.ssh"
    chmod 600 "$TARGET_HOME/.ssh/authorized_keys"
fi

# Enable passwordless sudo for user (temporary, for setup)
echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-cloud-init-users
chmod 440 /etc/sudoers.d/90-cloud-init-users

# Set timezone
timedatectl set-timezone Europe/Berlin

echo "Base configuration complete"
SCRIPT

    log_success "Base configuration complete"
}

# ============================================
# Phase 3: Security Stack
# ============================================

configure_security() {
    log_step "Installing security stack"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would install: UFW, Fail2ban, SSH hardening, rkhunter"
        return 0
    fi

    # Copy security configs
    log_substep "Uploading security configurations"
    remote_exec "mkdir -p /tmp/nyx-setup/security"
    remote_copy "${REPO_DIR}/security/ufw-setup.sh" "/tmp/nyx-setup/security/"
    remote_copy "${REPO_DIR}/security/fail2ban-jail.local" "/tmp/nyx-setup/security/"
    remote_copy "${REPO_DIR}/security/sshd-hardening.conf" "/tmp/nyx-setup/security/"
    remote_copy "${REPO_DIR}/security/setup-security.sh" "/tmp/nyx-setup/security/"

    # Run security setup
    log_substep "Running security setup"
    remote_exec "chmod +x /tmp/nyx-setup/security/*.sh && /tmp/nyx-setup/security/setup-security.sh"

    log_success "Security stack installed"
}

# ============================================
# Phase 4: Secrets Import
# ============================================

import_secrets() {
    if [[ $SKIP_SECRETS -eq 1 ]]; then
        log_step "Skipping secrets import"
        return 0
    fi

    log_step "Importing secrets bundle"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would import secrets from: $SECRETS_BUNDLE"
        return 0
    fi

    # Install age on remote
    log_substep "Installing age encryption tool"
    remote_exec "bash -s" <<'SCRIPT'
if ! command -v age &>/dev/null; then
    echo "Installing age..."
    AGE_VERSION="1.1.1"
    curl -sLO "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz"
    tar -xzf "age-v${AGE_VERSION}-linux-amd64.tar.gz"
    mv age/age age/age-keygen /usr/local/bin/
    rm -rf age "age-v${AGE_VERSION}-linux-amd64.tar.gz"
fi
age --version
SCRIPT

    # Copy import script and bundle
    log_substep "Uploading secrets bundle"
    remote_exec "mkdir -p /tmp/nyx-setup/provision/lib"
    remote_copy "${SCRIPT_DIR}/lib/logging.sh" "/tmp/nyx-setup/provision/lib/"
    remote_copy "${SCRIPT_DIR}/nyx-import-secrets.sh" "/tmp/nyx-setup/provision/"
    remote_copy "$SECRETS_BUNDLE" "/tmp/nyx-secrets-bundle.tar.gz.age"

    # Run import (interactive - needs passphrase)
    log_substep "Running secrets import"
    log_warn "You will be prompted for the bundle passphrase"
    echo ""

    local host="${EXISTING_SERVER:-root@${SERVER_IP}}"
    ssh -t -o StrictHostKeyChecking=no "$host" \
        "chmod +x /tmp/nyx-setup/provision/nyx-import-secrets.sh && /tmp/nyx-setup/provision/nyx-import-secrets.sh --bundle /tmp/nyx-secrets-bundle.tar.gz.age --user $TARGET_USER"

    # Cleanup bundle from remote
    remote_exec "rm -f /tmp/nyx-secrets-bundle.tar.gz.age"

    log_success "Secrets imported"
}

# ============================================
# Phase 5: Software Installation
# ============================================

install_software() {
    if [[ $SKIP_SOFTWARE -eq 1 ]]; then
        log_step "Skipping software installation"
        return 0
    fi

    log_step "Installing software stack"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would install packages from config/nyx-packages.txt"
        log_info "[DRY-RUN] Would install: Node.js 22, sops, gh, rclone, clawdbot"
        return 0
    fi

    # Upload packages list
    log_substep "Uploading package list"
    remote_copy "${REPO_DIR}/config/nyx-packages.txt" "/tmp/nyx-setup/"

    remote_exec "bash -s" <<'SCRIPT'
set -e

TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"
PACKAGES_FILE="/tmp/nyx-setup/nyx-packages.txt"

echo "==> Installing apt packages from config..."
if [[ -f "$PACKAGES_FILE" ]]; then
    # Filter out comments and blank lines, install packages
    grep -vE '^\s*#|^\s*$' "$PACKAGES_FILE" | xargs apt-get install -y -qq
    echo "Installed packages from nyx-packages.txt"
else
    echo "WARN: Package list not found, installing defaults..."
    apt-get install -y -qq curl jq git fail2ban ufw rkhunter ffmpeg pandoc rsync
fi

echo "==> Installing Node.js 22..."
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
fi
node --version

echo "==> Installing SOPS..."
if ! command -v sops &>/dev/null; then
    SOPS_VERSION="3.8.1"
    curl -sLO "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64"
    mv "sops-v${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
fi
sops --version

echo "==> Installing GitHub CLI..."
if ! command -v gh &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq gh
fi
gh --version

echo "==> Installing rclone..."
if ! command -v rclone &>/dev/null; then
    curl https://rclone.org/install.sh | bash
fi
rclone --version

echo "==> Setting up npm global directory for user..."
su - "$TARGET_USER" -c "
    mkdir -p ~/.local/share/npm-global
    npm config set prefix ~/.local/share/npm-global
    echo 'export PATH=~/.local/share/npm-global/bin:\$PATH' >> ~/.bashrc
"

echo "==> Installing clawdbot globally..."
su - "$TARGET_USER" -c "
    export PATH=~/.local/share/npm-global/bin:\$PATH
    npm install -g clawdbot
    clawdbot --version || echo 'clawdbot installed'
"

echo "Software installation complete"
SCRIPT

    log_success "Software installed"
}

# ============================================
# Phase 6: Service Configuration
# ============================================

configure_service() {
    log_step "Configuring clawdbot service"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would configure: systemd service, tmpfs mount, decrypt scripts"
        return 0
    fi

    # Copy config files
    log_substep "Uploading service configurations"
    remote_exec "mkdir -p /tmp/nyx-setup/config/sudoers.d"
    remote_copy "${REPO_DIR}/config/clawdbot.service" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/clawdbot-runtime.mount" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/clawdbot-start.sh" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/clawdbot-decrypt.sh" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/sops-decrypt-config" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/age-decrypt-token" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/sudoers.d/clawdbot-decrypt" "/tmp/nyx-setup/config/sudoers.d/"

    remote_exec "bash -s" <<'SCRIPT'
set -e

TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"
CONFIG_DIR="/tmp/nyx-setup/config"

echo "==> Installing systemd service..."
cp "$CONFIG_DIR/clawdbot.service" /etc/systemd/system/
cp "$CONFIG_DIR/clawdbot-runtime.mount" /etc/systemd/system/home-fx-.clawdbot-runtime.mount

echo "==> Installing helper scripts..."
cp "$CONFIG_DIR/clawdbot-start.sh" /usr/local/bin/
cp "$CONFIG_DIR/clawdbot-decrypt.sh" /usr/local/bin/
cp "$CONFIG_DIR/sops-decrypt-config" /usr/local/bin/
cp "$CONFIG_DIR/age-decrypt-token" /usr/local/bin/

chmod 755 /usr/local/bin/clawdbot-*.sh
chmod 755 /usr/local/bin/sops-decrypt-config
chmod 755 /usr/local/bin/age-decrypt-token

echo "==> Installing sudoers rules..."
cp "$CONFIG_DIR/sudoers.d/clawdbot-decrypt" /etc/sudoers.d/
chmod 440 /etc/sudoers.d/clawdbot-decrypt

# Validate sudoers
if ! visudo -cf /etc/sudoers.d/clawdbot-decrypt; then
    echo "ERROR: Invalid sudoers configuration"
    rm -f /etc/sudoers.d/clawdbot-decrypt
    exit 1
fi

echo "==> Creating required directories..."
mkdir -p "$TARGET_HOME/.clawdbot/runtime"
mkdir -p "$TARGET_HOME/.secrets"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.clawdbot" "$TARGET_HOME/.secrets"

echo "==> Enabling user lingering..."
loginctl enable-linger "$TARGET_USER"

echo "==> Reloading systemd..."
systemctl daemon-reload

echo "==> Enabling services..."
systemctl enable home-fx-.clawdbot-runtime.mount
systemctl enable clawdbot.service

echo "Service configuration complete"
SCRIPT

    log_success "Service configured"
}

# ============================================
# Phase 7: Workspace Restore
# ============================================

restore_workspace() {
    if [[ $SKIP_WORKSPACE -eq 1 ]]; then
        log_step "Skipping workspace restore"
        return 0
    fi

    log_step "Restoring workspace from Dropbox"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would restore ~/clawd/ from Dropbox backup"
        return 0
    fi

    remote_exec "bash -s" <<'SCRIPT'
set -e

TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"
CLAWD_DIR="$TARGET_HOME/clawd"

# Check if rclone is configured
if [[ ! -f "$TARGET_HOME/.config/rclone/rclone.conf" ]]; then
    echo "WARN: rclone not configured, skipping workspace restore"
    echo "Configure rclone manually: rclone config"
    exit 0
fi

# Check if remote exists
if ! su - "$TARGET_USER" -c "rclone listremotes" | grep -q "dropbox:"; then
    echo "WARN: Dropbox remote not configured in rclone"
    exit 0
fi

# Check if backup exists
if ! su - "$TARGET_USER" -c "rclone lsf dropbox:nyx-backup/clawd/" &>/dev/null; then
    echo "WARN: No backup found at dropbox:nyx-backup/clawd/"
    echo "Creating empty workspace..."
    mkdir -p "$CLAWD_DIR"
    chown "$TARGET_USER:$TARGET_USER" "$CLAWD_DIR"
    exit 0
fi

echo "==> Restoring workspace from Dropbox..."
su - "$TARGET_USER" -c "rclone sync dropbox:nyx-backup/clawd/ ~/clawd/ --progress"

echo "Workspace restored"
SCRIPT

    log_success "Workspace restore complete"
}

# ============================================
# Phase 8: Tailscale
# ============================================

setup_tailscale() {
    if [[ $SKIP_TAILSCALE -eq 1 ]]; then
        log_step "Skipping Tailscale setup"
        return 0
    fi

    log_step "Setting up Tailscale"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would install and configure Tailscale"
        return 0
    fi

    remote_exec "bash -s" <<'SCRIPT'
set -e

echo "==> Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> Starting Tailscale..."
systemctl enable tailscaled
systemctl start tailscaled

# Check if already authenticated
if tailscale status &>/dev/null; then
    echo "Tailscale already connected:"
    tailscale status
else
    echo ""
    echo "=========================================="
    echo "Tailscale needs authentication!"
    echo "Run on the server: tailscale up"
    echo "=========================================="
    echo ""
fi
SCRIPT

    log_success "Tailscale setup complete"
}

# ============================================
# Phase 9: Backup Scripts & Cron Setup
# ============================================

setup_backups() {
    log_step "Setting up backup scripts and cron jobs"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would configure: Dropbox backup, NAS backup, security scan"
        log_info "[DRY-RUN] Cron jobs: 3:00am Dropbox, 3:30am NAS, 4:00am Sunday security"
        return 0
    fi

    # Copy all backup scripts
    log_substep "Uploading backup and security scripts"
    remote_copy "${REPO_DIR}/scripts/backup-to-dropbox.sh" "/tmp/nyx-setup/"
    remote_copy "${REPO_DIR}/scripts/backup-to-nas.sh" "/tmp/nyx-setup/"
    remote_copy "${REPO_DIR}/scripts/security-scan.sh" "/tmp/nyx-setup/"

    remote_exec "bash -s" <<'SCRIPT'
set -e

TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"

echo "==> Installing backup and security scripts..."

# Install Dropbox backup script
if [[ -f "/tmp/nyx-setup/backup-to-dropbox.sh" ]]; then
    cp "/tmp/nyx-setup/backup-to-dropbox.sh" "${TARGET_HOME}/backup-to-dropbox.sh"
    chmod 755 "${TARGET_HOME}/backup-to-dropbox.sh"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/backup-to-dropbox.sh"
    echo "Installed: ${TARGET_HOME}/backup-to-dropbox.sh"
fi

# Install NAS backup script
if [[ -f "/tmp/nyx-setup/backup-to-nas.sh" ]]; then
    cp "/tmp/nyx-setup/backup-to-nas.sh" "${TARGET_HOME}/backup-to-nas.sh"
    chmod 755 "${TARGET_HOME}/backup-to-nas.sh"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/backup-to-nas.sh"
    echo "Installed: ${TARGET_HOME}/backup-to-nas.sh"
fi

# Install security scan script
if [[ -f "/tmp/nyx-setup/security-scan.sh" ]]; then
    cp "/tmp/nyx-setup/security-scan.sh" "${TARGET_HOME}/security-scan.sh"
    chmod 755 "${TARGET_HOME}/security-scan.sh"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/security-scan.sh"
    echo "Installed: ${TARGET_HOME}/security-scan.sh"
fi

echo "==> Checking prerequisites..."
# Check rsync password file for NAS backup
if [[ ! -f "${TARGET_HOME}/.rsync-nas-password" ]]; then
    echo "WARN: rsync password file not found at ${TARGET_HOME}/.rsync-nas-password"
    echo "NAS backup will need manual configuration"
fi

echo "==> Setting up cron jobs..."
# Get existing crontab
existing_cron=$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)

# Build new crontab
new_cron="$existing_cron"

# Add Dropbox backup (3:00am daily)
if ! echo "$existing_cron" | grep -q "backup-to-dropbox.sh"; then
    new_cron=$(echo "$new_cron"; echo "0 3 * * * ${TARGET_HOME}/backup-to-dropbox.sh")
    echo "Adding: 0 3 * * * ${TARGET_HOME}/backup-to-dropbox.sh"
else
    echo "Dropbox backup cron already exists"
fi

# Add NAS backup (3:30am daily)
if ! echo "$existing_cron" | grep -q "backup-to-nas.sh"; then
    new_cron=$(echo "$new_cron"; echo "30 3 * * * ${TARGET_HOME}/backup-to-nas.sh")
    echo "Adding: 30 3 * * * ${TARGET_HOME}/backup-to-nas.sh"
else
    echo "NAS backup cron already exists"
fi

# Add security scan (4:00am every Sunday)
if ! echo "$existing_cron" | grep -q "security-scan.sh"; then
    new_cron=$(echo "$new_cron"; echo "0 4 * * 0 ${TARGET_HOME}/security-scan.sh")
    echo "Adding: 0 4 * * 0 ${TARGET_HOME}/security-scan.sh"
else
    echo "Security scan cron already exists"
fi

# Apply new crontab (filter out blank lines)
echo "$new_cron" | grep -v '^$' | crontab -u "$TARGET_USER" -

echo "==> Verifying crontab..."
crontab -u "$TARGET_USER" -l

echo "Backup and security setup complete"
SCRIPT

    log_success "Backup scripts and cron jobs configured"
}

# ============================================
# Phase 10: Final Steps
# ============================================

final_steps() {
    log_step "Final configuration"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would start services and run verification"
        return 0
    fi

    # Start services
    log_substep "Starting clawdbot service"
    remote_exec "systemctl start clawdbot.service || true"

    # Check status
    log_substep "Checking service status"
    remote_exec "systemctl status clawdbot.service --no-pager || true"

    # Cleanup
    log_substep "Cleaning up"
    remote_exec "rm -rf /tmp/nyx-setup"

    log_success "Provisioning complete"
}

# ============================================
# Main
# ============================================

main() {
    parse_args "$@"

    banner "Nyx Server Provisioning"

    check_prerequisites

    log_info "Server name: $SERVER_NAME"
    log_info "Server type: $SERVER_TYPE"
    log_info "Location: $SERVER_LOCATION"
    [[ -n "$SECRETS_BUNDLE" ]] && log_info "Secrets bundle: $SECRETS_BUNDLE"
    [[ -n "$EXISTING_SERVER" ]] && log_info "Existing server: $EXISTING_SERVER"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warn "DRY-RUN MODE - No changes will be made"
    fi

    echo ""
    if ! confirm "Proceed with provisioning?"; then
        log_info "Cancelled"
        exit 0
    fi

    # Run provisioning phases
    create_hetzner_server
    configure_base
    configure_security
    import_secrets
    install_software
    configure_service
    restore_workspace
    setup_tailscale
    setup_backups
    final_steps

    separator
    echo ""
    log_success "Nyx server provisioned successfully!"
    echo ""
    echo "Server details:"
    [[ -n "${SERVER_IP:-}" ]] && echo "  IP: $SERVER_IP"
    echo "  Name: $SERVER_NAME"
    echo "  User: $TARGET_USER"
    echo ""
    echo "Next steps:"
    echo "  1. Connect via Tailscale: ssh $TARGET_USER@$SERVER_NAME"
    echo "  2. If Tailscale not connected: ssh root@${SERVER_IP:-$EXISTING_SERVER}"
    echo "  3. Run verification: ./provision/nyx-verify.sh"
    echo "  4. Check Telegram bot is responding"
    echo ""
}

main "$@"
