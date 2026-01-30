#!/bin/bash
# setup-nas-backup.sh - Setup NAS backup on Nyx server
#
# This script:
#   1. Creates the rsync password file
#   2. Installs the backup script
#   3. Configures the cron job
#   4. Tests connectivity
#
# Usage:
#   ./setup-nas-backup.sh                    # Interactive setup
#   ./setup-nas-backup.sh --password "xxx"   # Non-interactive with password

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${TARGET_USER:-fx}"
TARGET_HOME="/home/${TARGET_USER}"

# Configuration
RSYNC_PASSWORD=""
BACKUP_SCRIPT_SRC="${SCRIPT_DIR}/backup-to-nas.sh"
BACKUP_SCRIPT_DEST="${TARGET_HOME}/backup-to-nas.sh"
PASSWORD_FILE="${TARGET_HOME}/.rsync-nas-password"
CRON_TIME="30 3 * * *"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Setup NAS backup for Nyx server.

OPTIONS:
    -p, --password PASSWORD   Rsync password (will prompt if not provided)
    -h, --help               Show this help

EXAMPLES:
    $(basename "$0")                      # Interactive
    $(basename "$0") --password "secret"  # Non-interactive
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--password)
                RSYNC_PASSWORD="$2"
                shift 2
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
}

prompt_password() {
    if [[ -z "$RSYNC_PASSWORD" ]]; then
        echo ""
        echo "Enter the rsync password for the NAS backup module."
        echo "(This is configured in TerraMaster TOS under rsync daemon settings)"
        echo ""
        read -rsp "Rsync password: " RSYNC_PASSWORD
        echo ""

        if [[ -z "$RSYNC_PASSWORD" ]]; then
            log_error "Password cannot be empty"
            exit 1
        fi
    fi
}

create_password_file() {
    log_info "Creating rsync password file..."

    echo "$RSYNC_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    chown "${TARGET_USER}:${TARGET_USER}" "$PASSWORD_FILE"

    log_info "Password file created: $PASSWORD_FILE"
}

install_backup_script() {
    log_info "Installing backup script..."

    if [[ -f "$BACKUP_SCRIPT_SRC" ]]; then
        cp "$BACKUP_SCRIPT_SRC" "$BACKUP_SCRIPT_DEST"
    else
        log_error "Backup script not found: $BACKUP_SCRIPT_SRC"
        log_info "Please copy backup-to-nas.sh to $BACKUP_SCRIPT_DEST manually"
        return 1
    fi

    chmod 755 "$BACKUP_SCRIPT_DEST"
    chown "${TARGET_USER}:${TARGET_USER}" "$BACKUP_SCRIPT_DEST"

    log_info "Backup script installed: $BACKUP_SCRIPT_DEST"
}

setup_cron() {
    log_info "Setting up cron job..."

    # Get existing crontab
    local existing_cron
    existing_cron=$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)

    # Check if backup job already exists
    if echo "$existing_cron" | grep -q "backup-to-nas.sh"; then
        log_warn "NAS backup cron job already exists"
        return 0
    fi

    # Add new cron job
    (echo "$existing_cron"; echo "${CRON_TIME} ${BACKUP_SCRIPT_DEST}") | crontab -u "$TARGET_USER" -

    log_info "Cron job added: ${CRON_TIME} ${BACKUP_SCRIPT_DEST}"
}

show_crontab() {
    echo ""
    log_info "Current crontab for $TARGET_USER:"
    echo "----------------------------------------"
    crontab -u "$TARGET_USER" -l 2>/dev/null || echo "(empty)"
    echo "----------------------------------------"
}

test_connectivity() {
    log_info "Testing NAS connectivity..."
    echo ""

    if su - "$TARGET_USER" -c "$BACKUP_SCRIPT_DEST --test"; then
        log_info "Connectivity test passed!"
        return 0
    else
        log_error "Connectivity test failed"
        return 1
    fi
}

run_test_backup() {
    echo ""
    read -rp "Run a dry-run backup now? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        log_info "Running dry-run backup..."
        su - "$TARGET_USER" -c "$BACKUP_SCRIPT_DEST --dry-run"
    fi
}

main() {
    parse_args "$@"

    echo ""
    echo "========================================"
    echo "  Nyx NAS Backup Setup"
    echo "========================================"
    echo ""

    # Check if running as root (needed for crontab manipulation)
    if [[ $EUID -ne 0 ]]; then
        log_warn "Not running as root. Some operations may require sudo."
    fi

    # Verify target user exists
    if ! id "$TARGET_USER" &>/dev/null; then
        log_error "Target user not found: $TARGET_USER"
        exit 1
    fi

    prompt_password
    create_password_file
    install_backup_script
    setup_cron
    show_crontab

    echo ""
    if test_connectivity; then
        run_test_backup
    else
        log_warn "Fix connectivity issues before running backups"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check Tailscale is connected: tailscale status"
        echo "  2. Check NAS IP: ping 100.98.9.111"
        echo "  3. Check rsync port: nc -zv 100.98.9.111 873"
        echo "  4. Check rsync module: rsync --list-only rsync://rsync-user@100.98.9.111/backup/"
        echo "  5. Verify password in TerraMaster TOS rsync settings"
    fi

    echo ""
    echo "========================================"
    echo "  Setup Complete"
    echo "========================================"
    echo ""
    echo "Files created:"
    echo "  - $PASSWORD_FILE (rsync password)"
    echo "  - $BACKUP_SCRIPT_DEST (backup script)"
    echo ""
    echo "Backup schedule: Daily at 3:30am"
    echo ""
    echo "Manual commands:"
    echo "  Test:     $BACKUP_SCRIPT_DEST --test"
    echo "  Dry-run:  $BACKUP_SCRIPT_DEST --dry-run"
    echo "  Backup:   $BACKUP_SCRIPT_DEST"
    echo "  Logs:     cat ~/backup-nas.log"
    echo ""
}

main "$@"
