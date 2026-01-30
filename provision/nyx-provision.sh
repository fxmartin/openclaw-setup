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
SERVER_TYPE="cpx22"
SERVER_IMAGE="ubuntu-24.04"
SERVER_LOCATION="nbg1"
SSH_KEY_NAME=""  # Set dynamically by create_ssh_key()

# Target user
TARGET_USER="fx"
TARGET_HOME="/home/${TARGET_USER}"

# Secrets bundle
SECRETS_BUNDLE=""

# Existing server (skip Hetzner creation)
EXISTING_SERVER=""

# Dry run mode
DRY_RUN=0

# Update SSH config only mode
UPDATE_SSH_CONFIG_ONLY=""

# Skip specific phases
SKIP_HETZNER=0
SKIP_SECRETS=0
SKIP_SOFTWARE=0
SKIP_WORKSPACE=0
SKIP_TAILSCALE=0

# Workspace restore source: "dropbox" (default), "nas", or "fresh" (none)
RESTORE_SOURCE="dropbox"

# ============================================
# Usage
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Provision a new Nyx server on Hetzner Cloud.

OPTIONS:
    -b, --secrets-bundle FILE   Secrets bundle file (required for provisioning)
    -n, --server-name NAME      Server name (default: nyx)
    -t, --server-type TYPE      Server type (default: cpx22)
    -l, --location LOCATION     Server location (default: nbg1)
    -e, --existing-server HOST  Provision existing server (skip Hetzner creation)
    --ssh-key NAME              SSH key name in Hetzner (auto-created if not specified)
    --dry-run                   Show what would be done
    --update-ssh-config NAME    Update SSH config with Tailscale IP for server NAME
    --skip-secrets              Skip secrets import
    --skip-software             Skip software installation
    --skip-workspace            Skip workspace restore (same as --fresh)
    --skip-tailscale            Skip Tailscale setup
    --fresh                     Brand new bot: skip workspace restore entirely
    --restore-from-nas          Clone existing bot: restore workspace from NAS backup
    -h, --help                  Show this help message

EXAMPLES:
    # Clone existing bot (restore from NAS - recommended for DR)
    ./nyx-provision.sh --secrets-bundle ~/bundle.tar.gz.age --restore-from-nas

    # Brand new bot (fresh installation, no workspace restore)
    ./nyx-provision.sh --secrets-bundle ~/bundle.tar.gz.age --fresh

    # Default: restore from Dropbox
    ./nyx-provision.sh --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age

    # Provision existing server with NAS restore
    ./nyx-provision.sh --existing-server nyx.example.com --secrets-bundle ~/bundle.tar.gz.age --restore-from-nas

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
            --update-ssh-config)
                UPDATE_SSH_CONFIG_ONLY="$2"
                shift 2
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
                RESTORE_SOURCE="fresh"
                shift
                ;;
            --fresh)
                SKIP_WORKSPACE=1
                RESTORE_SOURCE="fresh"
                shift
                ;;
            --restore-from-nas)
                RESTORE_SOURCE="nas"
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
# Phase 1: SSH Key & Hetzner Server Creation
# ============================================

# Local SSH key path (set during key creation)
LOCAL_SSH_KEY=""

create_ssh_key() {
    log_step "Setting up SSH key for $SERVER_NAME"

    local key_name="openclaw-${SERVER_NAME}"
    local key_path="$HOME/.ssh/id_${SERVER_NAME}"

    # Check if local key already exists
    if [[ -f "$key_path" ]]; then
        log_info "Local SSH key already exists: $key_path"
        LOCAL_SSH_KEY="$key_path"

        # Generate public key if missing
        if [[ ! -f "${key_path}.pub" ]]; then
            ssh-keygen -y -f "$key_path" > "${key_path}.pub"
        fi
    else
        log_substep "Generating new SSH key pair"
        ssh-keygen -t ed25519 -f "$key_path" -N "" -C "${SERVER_NAME}@openclaw"
        chmod 600 "$key_path"
        LOCAL_SSH_KEY="$key_path"
        log_success "SSH key created: $key_path"
    fi

    # Check if key exists in Hetzner
    if hcloud ssh-key describe "$key_name" &>/dev/null; then
        log_info "SSH key '$key_name' already exists in Hetzner"
        SSH_KEY_NAME="$key_name"
        return 0
    fi

    # Upload to Hetzner
    log_substep "Uploading SSH key to Hetzner"
    if hcloud ssh-key create --name "$key_name" --public-key-from-file "${key_path}.pub" &>/dev/null; then
        log_success "SSH key uploaded to Hetzner: $key_name"
        SSH_KEY_NAME="$key_name"
    else
        # Key might already exist with different name (same fingerprint)
        log_warn "Could not upload SSH key (may already exist with different name)"
        log_info "Checking existing keys..."

        # Try to find a matching key by testing
        local existing_keys
        existing_keys=$(hcloud ssh-key list -o noheader -o columns=name)
        for existing_key in $existing_keys; do
            SSH_KEY_NAME="$existing_key"
            log_info "Will try using existing key: $SSH_KEY_NAME"
            return 0
        done

        log_fatal "No usable SSH key found in Hetzner"
    fi
}

create_hetzner_server() {
    # Always set up SSH key (needed for remote_exec even with existing server)
    create_ssh_key

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
            SERVER_IP=$(hcloud server ip "$SERVER_NAME")
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
        log_info "  Local Key: $LOCAL_SSH_KEY"
        return 0
    fi

    log_substep "Creating $SERVER_TYPE server in $SERVER_LOCATION"

    local server_output
    if ! server_output=$(hcloud server create \
        --name "$SERVER_NAME" \
        --type "$SERVER_TYPE" \
        --image "$SERVER_IMAGE" \
        --location "$SERVER_LOCATION" \
        --ssh-key "$SSH_KEY_NAME" \
        --poll-interval 2s \
        2>&1); then
        log_error "Server creation failed:"
        log_error "$server_output"
        exit 1
    fi

    log_debug "$server_output"

    # Get server IP
    SERVER_IP=$(hcloud server ip "$SERVER_NAME")
    log_success "Server created: $SERVER_NAME ($SERVER_IP)"

    # Wait for SSH to be ready
    log_substep "Waiting for SSH to be ready"
    local max_attempts=30
    local attempt=0
    local ssh_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes"
    [[ -n "$LOCAL_SSH_KEY" ]] && ssh_opts="$ssh_opts -i $LOCAL_SSH_KEY"

    while [[ $attempt -lt $max_attempts ]]; do
        # shellcheck disable=SC2086
        if ssh $ssh_opts "root@${SERVER_IP}" "echo ready" &>/dev/null; then
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
    local ssh_opts="-o StrictHostKeyChecking=no -o BatchMode=yes"
    [[ -n "$LOCAL_SSH_KEY" ]] && ssh_opts="$ssh_opts -i $LOCAL_SSH_KEY"
    # shellcheck disable=SC2086
    ssh $ssh_opts "$host" "$@"
}

remote_exec_script() {
    local script="$1"
    local host="${EXISTING_SERVER:-root@${SERVER_IP}}"
    local ssh_opts="-o StrictHostKeyChecking=no -o BatchMode=yes"
    [[ -n "$LOCAL_SSH_KEY" ]] && ssh_opts="$ssh_opts -i $LOCAL_SSH_KEY"
    # shellcheck disable=SC2086
    ssh $ssh_opts "$host" "bash -s" < "$script"
}

remote_copy() {
    local src="$1"
    local dest="$2"
    local host="${EXISTING_SERVER:-root@${SERVER_IP}}"
    local scp_opts="-o StrictHostKeyChecking=no"
    [[ -n "$LOCAL_SSH_KEY" ]] && scp_opts="$scp_opts -i $LOCAL_SSH_KEY"
    # shellcheck disable=SC2086
    scp $scp_opts "$src" "${host}:${dest}"
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

    # Run security setup (skip SSH hardening until final phase)
    log_substep "Running security setup"
    remote_exec "chmod +x /tmp/nyx-setup/security/*.sh && /tmp/nyx-setup/security/setup-security.sh --skip-ssh-hardening"

    log_success "Security stack installed (SSH hardening deferred to final phase)"
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

    # Install prerequisites for secrets import
    log_substep "Installing prerequisites (age, jq)"
    remote_exec "bash -s" <<'SCRIPT'
# Install jq if missing
if ! command -v jq &>/dev/null; then
    echo "Installing jq..."
    apt-get update -qq && apt-get install -y -qq jq
fi

# Install age if missing
if ! command -v age &>/dev/null; then
    echo "Installing age..."
    AGE_VERSION="1.1.1"
    curl -sLO "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz"
    tar -xzf "age-v${AGE_VERSION}-linux-amd64.tar.gz"
    mv age/age age/age-keygen /usr/local/bin/
    rm -rf age "age-v${AGE_VERSION}-linux-amd64.tar.gz"
fi

echo "jq: $(jq --version)"
echo "age: $(age --version)"
SCRIPT

    # Copy import script and bundle
    log_substep "Uploading secrets bundle"
    remote_exec "mkdir -p /tmp/nyx-setup/provision/lib"
    remote_copy "${SCRIPT_DIR}/lib/logging.sh" "/tmp/nyx-setup/provision/lib/"
    remote_copy "${SCRIPT_DIR}/nyx-import-secrets.sh" "/tmp/nyx-setup/provision/"
    remote_copy "$SECRETS_BUNDLE" "/tmp/nyx-secrets-bundle.tar.gz.age"

    # Prompt for passphrase locally
    log_substep "Running secrets import"
    echo ""
    echo -e "${YELLOW}Enter the passphrase for the secrets bundle:${NC}"
    read -rs BUNDLE_PASSPHRASE
    echo ""

    if [[ -z "$BUNDLE_PASSPHRASE" ]]; then
        log_fatal "Passphrase is required"
    fi

    # Run import with passphrase via stdin (secure - not exposed in process list)
    log_debug "Passing passphrase via stdin to remote import script"
    local host="${EXISTING_SERVER:-root@${SERVER_IP}}"
    local ssh_opts="-o StrictHostKeyChecking=no -o BatchMode=yes"
    [[ -n "$LOCAL_SSH_KEY" ]] && ssh_opts="$ssh_opts -i $LOCAL_SSH_KEY"

    # Pipe passphrase to remote script via stdin
    # shellcheck disable=SC2086
    echo "$BUNDLE_PASSPHRASE" | ssh $ssh_opts "$host" \
        "chmod +x /tmp/nyx-setup/provision/nyx-import-secrets.sh && /tmp/nyx-setup/provision/nyx-import-secrets.sh --bundle /tmp/nyx-secrets-bundle.tar.gz.age --user $TARGET_USER --passphrase-stdin --yes"

    # Clear passphrase from memory
    BUNDLE_PASSPHRASE=""

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
        log_info "[DRY-RUN] Would install: Node.js 22, sops, gh, rclone, openclaw"
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

echo "==> Installing openclaw globally..."
su - "$TARGET_USER" -c "
    export PATH=~/.local/share/npm-global/bin:\$PATH
    npm install -g openclaw
    openclaw --version || echo 'openclaw installed'
"

echo "Software installation complete"
SCRIPT

    log_success "Software installed"
}

# ============================================
# Phase 6: Service Configuration
# ============================================

configure_service() {
    log_step "Configuring openclaw service"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would configure: systemd service, tmpfs mount, decrypt scripts"
        return 0
    fi

    # Copy config files
    log_substep "Uploading service configurations"
    remote_exec "mkdir -p /tmp/nyx-setup/config/sudoers.d"
    remote_copy "${REPO_DIR}/config/openclaw.service" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/openclaw-runtime.mount" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/openclaw-start.sh" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/openclaw-decrypt.sh" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/sops-decrypt-config" "/tmp/nyx-setup/config/"
    remote_copy "${REPO_DIR}/config/sudoers.d/openclaw-decrypt" "/tmp/nyx-setup/config/sudoers.d/"

    remote_exec "bash -s" <<'SCRIPT'
set -e

TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"
CONFIG_DIR="/tmp/nyx-setup/config"

echo "==> Installing systemd service..."
cp "$CONFIG_DIR/openclaw.service" /etc/systemd/system/
cp "$CONFIG_DIR/openclaw-runtime.mount" /etc/systemd/system/home-fx-.openclaw-runtime.mount

echo "==> Installing helper scripts..."
cp "$CONFIG_DIR/openclaw-start.sh" /usr/local/bin/
cp "$CONFIG_DIR/openclaw-decrypt.sh" /usr/local/bin/
cp "$CONFIG_DIR/sops-decrypt-config" /usr/local/bin/

chmod 755 /usr/local/bin/openclaw-*.sh
chmod 755 /usr/local/bin/sops-decrypt-config

echo "==> Installing sudoers rules..."
cp "$CONFIG_DIR/sudoers.d/openclaw-decrypt" /etc/sudoers.d/
chmod 440 /etc/sudoers.d/openclaw-decrypt

# Validate sudoers
if ! visudo -cf /etc/sudoers.d/openclaw-decrypt; then
    echo "ERROR: Invalid sudoers configuration"
    rm -f /etc/sudoers.d/openclaw-decrypt
    exit 1
fi

echo "==> Creating required directories..."
mkdir -p "$TARGET_HOME/.openclaw/runtime"
mkdir -p "$TARGET_HOME/.secrets"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.openclaw" "$TARGET_HOME/.secrets"

echo "==> Enabling user lingering..."
loginctl enable-linger "$TARGET_USER"

echo "==> Reloading systemd..."
systemctl daemon-reload

echo "==> Enabling services..."
systemctl enable home-fx-.openclaw-runtime.mount
systemctl enable openclaw.service

echo "Service configuration complete"
SCRIPT

    log_success "Service configured"
}

# ============================================
# Phase 7: Workspace Restore
# ============================================

restore_workspace() {
    if [[ $SKIP_WORKSPACE -eq 1 ]] || [[ "$RESTORE_SOURCE" == "fresh" ]]; then
        log_step "Skipping workspace restore (fresh installation)"
        remote_exec "bash -s" <<'SCRIPT'
TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"
echo "Creating empty workspace directories..."
mkdir -p "$TARGET_HOME/clawd"
mkdir -p "$TARGET_HOME/.openclaw"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/clawd" "$TARGET_HOME/.openclaw"
echo "Fresh workspace created"
SCRIPT
        log_success "Fresh workspace created"
        return 0
    fi

    if [[ "$RESTORE_SOURCE" == "nas" ]]; then
        restore_workspace_from_nas
    else
        restore_workspace_from_dropbox
    fi
}

restore_workspace_from_dropbox() {
    log_step "Restoring workspace from Dropbox"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would restore ~/clawd/ and ~/.openclaw/ from Dropbox backup"
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

echo "==> Restoring clawd workspace from Dropbox..."
su - "$TARGET_USER" -c "rclone sync dropbox:nyx-backup/clawd/ ~/clawd/ --progress"

echo "==> Restoring openclaw config from Dropbox..."
if su - "$TARGET_USER" -c "rclone lsf dropbox:nyx-backup/openclaw/" &>/dev/null; then
    su - "$TARGET_USER" -c "rclone sync dropbox:nyx-backup/openclaw/ ~/.openclaw/ --progress --exclude 'runtime/**'"
else
    echo "WARN: No openclaw backup found at dropbox:nyx-backup/openclaw/"
fi

echo "Workspace restored from Dropbox"
SCRIPT

    log_success "Workspace restore from Dropbox complete"
}

restore_workspace_from_nas() {
    log_step "Restoring workspace from NAS (clone mode)"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would restore ~/clawd/ and ~/.openclaw/ from NAS backup"
        return 0
    fi

    # Copy restore script to server
    log_substep "Uploading NAS restore script"
    remote_copy "${REPO_DIR}/scripts/restore-from-nas.sh" "/tmp/nyx-setup/"

    # Check NAS prerequisites
    log_substep "Checking NAS connectivity prerequisites"
    remote_exec "bash -s" <<'SCRIPT'
set -e

TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"
RSYNC_PASSWORD_FILE="$TARGET_HOME/.rsync-nas-password"
RSYNC_HOST="100.98.9.111"

# Check if rsync password file exists
if [[ ! -f "$RSYNC_PASSWORD_FILE" ]]; then
    echo ""
    echo "ERROR: Rsync password file not found: $RSYNC_PASSWORD_FILE"
    echo ""
    echo "To set up NAS restore, create the password file:"
    echo "  echo 'YOUR_RSYNC_PASSWORD' > $RSYNC_PASSWORD_FILE"
    echo "  chmod 600 $RSYNC_PASSWORD_FILE"
    echo ""
    exit 1
fi

# Check NAS reachability via Tailscale
echo "Checking NAS reachability at $RSYNC_HOST:873..."
if ! nc -z -w5 "$RSYNC_HOST" 873 2>/dev/null; then
    echo ""
    echo "ERROR: Cannot reach NAS rsync port via Tailscale"
    echo ""
    echo "Ensure:"
    echo "  1. Tailscale is connected: tailscale status"
    echo "  2. NAS is online at $RSYNC_HOST"
    echo "  3. Rsync daemon is running on NAS port 873"
    echo ""
    exit 1
fi

echo "NAS is reachable"
SCRIPT

    # Run restore
    log_substep "Restoring workspace from NAS"
    remote_exec "bash -s" <<'SCRIPT'
set -e

TARGET_USER="fx"
TARGET_HOME="/home/$TARGET_USER"
RESTORE_SCRIPT="/tmp/nyx-setup/restore-from-nas.sh"

# Install restore script for future use
cp "$RESTORE_SCRIPT" "${TARGET_HOME}/restore-from-nas.sh"
chmod 755 "${TARGET_HOME}/restore-from-nas.sh"
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/restore-from-nas.sh"

# Run restore with --force (non-interactive)
echo "==> Running NAS restore..."
su - "$TARGET_USER" -c "bash $RESTORE_SCRIPT --force"

echo "Workspace restored from NAS"
SCRIPT

    log_success "Workspace restore from NAS complete"
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
    log_substep "Uploading backup, restore, and security scripts"
    remote_copy "${REPO_DIR}/scripts/backup-to-dropbox.sh" "/tmp/nyx-setup/"
    remote_copy "${REPO_DIR}/scripts/backup-to-nas.sh" "/tmp/nyx-setup/"
    remote_copy "${REPO_DIR}/scripts/restore-from-nas.sh" "/tmp/nyx-setup/"
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

# Install NAS restore script (for disaster recovery)
if [[ -f "/tmp/nyx-setup/restore-from-nas.sh" ]]; then
    cp "/tmp/nyx-setup/restore-from-nas.sh" "${TARGET_HOME}/restore-from-nas.sh"
    chmod 755 "${TARGET_HOME}/restore-from-nas.sh"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/restore-from-nas.sh"
    echo "Installed: ${TARGET_HOME}/restore-from-nas.sh"
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
# ============================================
# SSH Config Management
# ============================================

update_ssh_config() {
    local tailscale_ip="${1:-}"
    local config_dir="$HOME/.ssh/config.d"
    local config_file="$config_dir/openclaw-servers"

    log_step "Updating local SSH config"

    # Create config.d directory if needed
    mkdir -p "$config_dir"

    # Determine which IP to use for the main entry
    local main_ip="${tailscale_ip:-$SERVER_IP}"
    local ip_comment=""
    if [[ -z "$tailscale_ip" ]]; then
        ip_comment="  # TODO: Update HostName to Tailscale IP after authentication"
    fi

    # Check if entry already exists, remove it first
    if [[ -f "$config_file" ]]; then
        # Remove existing entries for this server
        sed -i.bak "/^# --- $SERVER_NAME ---$/,/^# --- end $SERVER_NAME ---$/d" "$config_file" 2>/dev/null || true
        rm -f "${config_file}.bak"
    fi

    # Append new entries
    cat >> "$config_file" << EOF

# --- $SERVER_NAME ---
# Added by nyx-provision.sh on $(date '+%Y-%m-%d %H:%M')

# Root access via public IP (for initial setup)
Host ${SERVER_NAME}-root
    HostName $SERVER_IP
    User root
    IdentityFile $LOCAL_SSH_KEY
    StrictHostKeyChecking no

# User access (use Tailscale IP when available)
Host $SERVER_NAME
    HostName $main_ip$ip_comment
    User $TARGET_USER
    IdentityFile $LOCAL_SSH_KEY
    StrictHostKeyChecking no

# --- end $SERVER_NAME ---
EOF

    chmod 600 "$config_file"

    # Check if main SSH config includes config.d
    local main_config="$HOME/.ssh/config"
    if [[ -f "$main_config" ]] && ! grep -q "Include.*config.d" "$main_config" 2>/dev/null; then
        # Main config exists but doesn't include config.d
        if [[ -L "$main_config" ]]; then
            # It's a symlink (Nix-managed), can't modify
            log_warn "SSH config is Nix-managed. Add this to your home-manager config:"
            echo ""
            echo "  programs.ssh.includes = [ \"~/.ssh/config.d/*\" ];"
            echo ""
        else
            # Regular file, prepend Include directive
            local temp_config
            temp_config=$(mktemp)
            echo "Include ~/.ssh/config.d/*" > "$temp_config"
            echo "" >> "$temp_config"
            cat "$main_config" >> "$temp_config"
            mv "$temp_config" "$main_config"
            log_success "Added Include directive to ~/.ssh/config"
        fi
    fi

    log_success "SSH config updated: $config_file"
    log_info "You can now use: ssh ${SERVER_NAME}-root (root) or ssh $SERVER_NAME (${TARGET_USER})"
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
    log_substep "Starting openclaw service"
    remote_exec "systemctl start openclaw.service || true"

    # Check status
    log_substep "Checking service status"
    remote_exec "systemctl status openclaw.service --no-pager || true"

    # Apply SSH hardening (now that fx user is fully set up)
    log_substep "Applying SSH hardening"
    remote_exec "bash -s" <<'SCRIPT'
set -e
SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"
HARDENING_SRC="/tmp/nyx-setup/security/sshd-hardening.conf"

if [[ -f "$HARDENING_SRC" ]]; then
    mkdir -p "$SSH_CONFIG_DIR"
    cp "$HARDENING_SRC" "${SSH_CONFIG_DIR}/99-hardening.conf"
    echo "Installed SSH hardening configuration"

    if sshd -t; then
        echo "SSH configuration valid"
        systemctl restart ssh
        echo "SSH service restarted with hardening"
    else
        echo "ERROR: SSH configuration test failed!"
        rm -f "${SSH_CONFIG_DIR}/99-hardening.conf"
        echo "Removed invalid configuration"
    fi
else
    echo "WARN: SSH hardening config not found, skipping"
fi
SCRIPT

    # Cleanup
    log_substep "Cleaning up"
    remote_exec "rm -rf /tmp/nyx-setup"

    log_success "Provisioning complete"
}

# ============================================
# Main
# ============================================

update_ssh_config_standalone() {
    local server_name="$1"
    local key_path="$HOME/.ssh/id_${server_name}"
    local config_file="$HOME/.ssh/config.d/openclaw-servers"

    log_step "Fetching Tailscale IP for $server_name"

    # Check if SSH key exists
    if [[ ! -f "$key_path" ]]; then
        log_fatal "SSH key not found: $key_path"
    fi

    # Get server IP from Hetzner
    local public_ip
    public_ip=$(hcloud server ip "$server_name" 2>/dev/null || echo "")
    if [[ -z "$public_ip" ]]; then
        log_fatal "Server '$server_name' not found in Hetzner"
    fi

    # Get Tailscale IP from server
    log_substep "Connecting to $server_name to get Tailscale IP"
    local tailscale_ip
    tailscale_ip=$(ssh -i "$key_path" -o StrictHostKeyChecking=no -o BatchMode=yes \
        "root@${public_ip}" "tailscale ip -4 2>/dev/null" 2>/dev/null || echo "")

    if [[ -z "$tailscale_ip" ]]; then
        log_error "Could not get Tailscale IP. Is Tailscale authenticated?"
        log_info "Run: ssh -i $key_path root@$public_ip 'tailscale up'"
        exit 1
    fi

    log_success "Tailscale IP: $tailscale_ip"

    # Update the SSH config file
    if [[ -f "$config_file" ]]; then
        log_substep "Updating SSH config with Tailscale IP"
        # Update the HostName for the main entry (non-root)
        sed -i.bak "s/^Host ${server_name}$/Host ${server_name}\n# Updated with Tailscale IP on $(date '+%Y-%m-%d %H:%M')/" "$config_file" 2>/dev/null || true
        # Replace HostName line after "Host server_name" section
        sed -i.bak "/^Host ${server_name}$/,/^Host /{s/HostName .*/HostName $tailscale_ip/}" "$config_file" 2>/dev/null || true
        # Remove TODO comment if present
        sed -i.bak "s/  # TODO: Update HostName.*$//" "$config_file" 2>/dev/null || true
        rm -f "${config_file}.bak"
        log_success "SSH config updated"
    else
        log_warn "SSH config file not found: $config_file"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  Server:       $server_name"
    echo "  Public IP:    $public_ip"
    echo "  Tailscale IP: $tailscale_ip"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "You can now connect with: ssh $server_name"
    echo ""
}

main() {
    parse_args "$@"

    # Handle standalone --update-ssh-config mode
    if [[ -n "$UPDATE_SSH_CONFIG_ONLY" ]]; then
        update_ssh_config_standalone "$UPDATE_SSH_CONFIG_ONLY"
        exit 0
    fi

    banner "Nyx Server Provisioning"

    check_prerequisites

    log_info "Server name: $SERVER_NAME"
    log_info "Server type: $SERVER_TYPE"
    log_info "Location: $SERVER_LOCATION"
    log_info "Workspace restore: $RESTORE_SOURCE"
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

    # Try to get Tailscale IP (may not be available if not authenticated yet)
    local tailscale_ip=""
    tailscale_ip=$(remote_exec "tailscale ip -4 2>/dev/null" 2>/dev/null || echo "")

    # Update local SSH config
    update_ssh_config "$tailscale_ip"

    separator
    echo ""
    log_success "Nyx server provisioned successfully!"
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "                     SERVER SUMMARY"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "  Server Name:      $SERVER_NAME"
    echo "  Public IP:        ${SERVER_IP:-N/A}"
    if [[ -n "$tailscale_ip" ]]; then
        echo "  Tailscale IP:     $tailscale_ip"
    else
        echo "  Tailscale IP:     (pending authentication)"
    fi
    echo ""
    echo "  SSH Private Key:  ${LOCAL_SSH_KEY:-N/A}"
    echo "  SSH Public Key:   ${LOCAL_SSH_KEY:-N/A}.pub"
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "Next steps:"
    echo "  1. Authenticate Tailscale:"
    echo "     ssh ${SERVER_NAME}-root 'tailscale up'"
    echo ""
    echo "  2. After Tailscale auth, update SSH config with Tailscale IP:"
    echo "     Run: ./provision/nyx-provision.sh --update-ssh-config $SERVER_NAME"
    echo ""
    echo "  3. Then connect via: ssh $SERVER_NAME"
    echo ""
    echo "  4. Run verification:"
    echo "     ./provision/nyx-verify.sh --remote $SERVER_NAME"
    echo ""
    echo "  5. Test Telegram bot is responding"
    echo ""
}

main "$@"
