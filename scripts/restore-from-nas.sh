#!/bin/bash
# restore-from-nas.sh - Restore Nyx workspace from Terramaster NAS via rsync
#
# Disaster recovery script to restore from NAS backup. Pulls data from NAS
# to local server. Always run with --dry-run first to preview changes.
#
# Prerequisites:
#   - ~/.rsync-nas-password with rsync password (chmod 600)
#   - NAS rsync daemon enabled on port 873
#   - Tailscale connected to NAS at 100.98.9.111
#
# Usage:
#   ./restore-from-nas.sh --dry-run    # Preview what would be restored (RECOMMENDED FIRST)
#   ./restore-from-nas.sh              # Restore from NAS
#   ./restore-from-nas.sh --test       # Test connectivity only
#   ./restore-from-nas.sh --list       # List available backups on NAS

set -euo pipefail

# ============================================
# Configuration
# ============================================

LOG_FILE="$HOME/restore-nas.log"
RSYNC_USER="rsync-user"
RSYNC_HOST="100.98.9.111"
RSYNC_MODULE="Backup"
RSYNC_PASSWORD_FILE="$HOME/.rsync-nas-password"
TELEGRAM_TOKEN_FILE="$HOME/.openclaw/runtime/telegram-bot-token"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-8332440542}"

# Excludes - don't restore these (will be regenerated)
CLAWD_EXCLUDES=(
    ".git"
    ".venv"
    "__pycache__"
    "node_modules"
    ".mypy_cache"
    "*.pyc"
    ".pytest_cache"
)

OPENCLAW_EXCLUDES=(
    "telegram"
    "agents/*/sessions"
    "runtime"
    "*.log"
)

# ============================================
# Helpers
# ============================================

DRY_RUN=0
TEST_ONLY=0
LIST_ONLY=0
FORCE=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$LOG_FILE"
}

get_telegram_token() {
    if [[ -f "$TELEGRAM_TOKEN_FILE" ]]; then
        cat "$TELEGRAM_TOKEN_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

send_telegram() {
    local message="$1"
    local token
    token=$(get_telegram_token)

    if [[ -n "$token" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$message" \
            -d parse_mode="Markdown" > /dev/null 2>&1 || true
    fi
}

on_error() {
    local msg
    msg="*Nyx Restore Failed*
Restore from NAS failed at $(date '+%Y-%m-%d %H:%M')
Check ~/restore-nas.log for details"
    log "ERROR: Restore failed"
    send_telegram "$msg"
    exit 1
}

check_prerequisites() {
    # Check password file
    if [[ ! -f "$RSYNC_PASSWORD_FILE" ]]; then
        log "ERROR: Rsync password file not found: $RSYNC_PASSWORD_FILE"
        log "Create it with: echo 'YOUR_PASSWORD' > $RSYNC_PASSWORD_FILE && chmod 600 $RSYNC_PASSWORD_FILE"
        return 1
    fi

    # Check password file permissions
    local perms
    perms=$(stat -c %a "$RSYNC_PASSWORD_FILE" 2>/dev/null || stat -f %Lp "$RSYNC_PASSWORD_FILE" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
        log "ERROR: Password file must have 600 permissions (currently: $perms)"
        log "Fix with: chmod 600 $RSYNC_PASSWORD_FILE"
        return 1
    fi

    return 0
}

check_nas_reachable() {
    log "Checking NAS reachability at $RSYNC_HOST:873..."
    if ! nc -z -w5 "$RSYNC_HOST" 873 2>/dev/null; then
        log "ERROR: Cannot reach NAS rsync port via Tailscale"
        return 1
    fi
    log "NAS is reachable"
    return 0
}

test_rsync_connection() {
    log "Testing rsync connection..."
    if rsync --list-only --password-file="$RSYNC_PASSWORD_FILE" \
        "rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/" >/dev/null 2>&1; then
        log "Rsync connection successful"
        return 0
    else
        log "ERROR: Rsync connection failed"
        return 1
    fi
}

list_backups() {
    echo "Available backups on NAS (${RSYNC_HOST}):"
    echo ""
    rsync --list-only --password-file="$RSYNC_PASSWORD_FILE" \
        "rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/nyx/" 2>/dev/null || {
        echo "ERROR: Could not list backups"
        return 1
    }
}

# ============================================
# Restore Functions
# ============================================

confirm_restore() {
    if [[ $FORCE -eq 1 ]]; then
        return 0
    fi

    echo ""
    echo "WARNING: This will overwrite local data with NAS backup!"
    echo ""
    echo "Source:      rsync://${RSYNC_HOST}/${RSYNC_MODULE}/nyx/"
    echo "Destination: ~/clawd/ and ~/.openclaw/"
    echo ""
    read -r -p "Are you sure you want to continue? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            echo "Restore cancelled."
            exit 0
            ;;
    esac
}

restore_clawd() {
    local src="rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/nyx/clawd/"
    local dest="$HOME/clawd/"

    # Create destination if it doesn't exist
    mkdir -p "$dest"

    log "Restoring clawd from NAS..."

    local rsync_opts="-avz --password-file=$RSYNC_PASSWORD_FILE"

    for exclude in "${CLAWD_EXCLUDES[@]}"; do
        rsync_opts+=" --exclude=$exclude"
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        rsync_opts+=" --dry-run"
    fi

    # shellcheck disable=SC2086
    rsync $rsync_opts "$src" "$dest" 2>&1 | tee -a "$LOG_FILE"

    log "Restore of clawd complete"
}

restore_openclaw() {
    local src="rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/nyx/openclaw/"
    local dest="$HOME/.openclaw/"

    # Create destination if it doesn't exist
    mkdir -p "$dest"

    log "Restoring openclaw from NAS..."

    # Check if source exists on NAS first
    if ! rsync --list-only --password-file="$RSYNC_PASSWORD_FILE" "$src" &>/dev/null; then
        log "WARN: openclaw backup not found on NAS (nyx/openclaw/) - skipping"
        log "This is normal for first-time setup; config will be created by secrets import"
        return 0
    fi

    local rsync_opts="-avz --password-file=$RSYNC_PASSWORD_FILE"

    for exclude in "${OPENCLAW_EXCLUDES[@]}"; do
        rsync_opts+=" --exclude=$exclude"
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        rsync_opts+=" --dry-run"
    fi

    # shellcheck disable=SC2086
    rsync $rsync_opts "$src" "$dest" 2>&1 | tee -a "$LOG_FILE"

    log "Restore of openclaw complete"
}

# ============================================
# Main
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Restore Nyx workspace from Terramaster NAS via rsync daemon.

OPTIONS:
    --dry-run    Show what would be restored without making changes (RECOMMENDED FIRST)
    --test       Test connectivity only
    --list       List available backups on NAS
    --force      Skip confirmation prompt
    -h, --help   Show this help

EXAMPLES:
    $(basename "$0") --dry-run    # Preview restore (do this first!)
    $(basename "$0") --list       # See what's on NAS
    $(basename "$0") --test       # Test NAS connectivity
    $(basename "$0")              # Perform restore (will prompt for confirmation)
    $(basename "$0") --force      # Restore without confirmation

IMPORTANT:
    Always run with --dry-run first to see what will be changed!
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --test)
                TEST_ONLY=1
                shift
                ;;
            --list)
                LIST_ONLY=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    # Rotate log if too large (>10MB)
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null) -gt 10485760 ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi

    log "========================================"
    log "Starting NAS restore"
    [[ $DRY_RUN -eq 1 ]] && log "DRY-RUN MODE - no changes will be made"

    # Prerequisites check
    if ! check_prerequisites; then
        exit 1
    fi

    # Connectivity check
    if ! check_nas_reachable; then
        exit 1
    fi

    # Test rsync connection
    if ! test_rsync_connection; then
        exit 1
    fi

    # List only mode
    if [[ $LIST_ONLY -eq 1 ]]; then
        list_backups
        exit 0
    fi

    # Exit if test only
    if [[ $TEST_ONLY -eq 1 ]]; then
        log "Test completed successfully"
        echo ""
        echo "All connectivity tests passed!"
        echo "NAS: $RSYNC_HOST"
        echo "Module: $RSYNC_MODULE"
        exit 0
    fi

    # Confirm before restore (unless dry-run or force)
    if [[ $DRY_RUN -eq 0 ]]; then
        confirm_restore
    fi

    # Set error trap
    trap on_error ERR

    # Run restores
    restore_clawd
    restore_openclaw

    log "NAS restore completed successfully"
    log "========================================"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo ""
        echo "Dry-run complete. Run without --dry-run to perform actual restore."
    else
        send_telegram "✓ Nyx restored from NAS backup"
        echo ""
        echo "Restore complete!"
        echo ""
        echo "Next steps:"
        echo "  1. Recreate Python venv: cd ~/clawd && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
        echo "  2. Reinstall node_modules if needed: cd ~/clawd && npm install"
        echo "  3. Restart service: sudo systemctl restart openclaw"
    fi
}

main "$@"
