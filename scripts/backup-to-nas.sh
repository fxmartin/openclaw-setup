#!/bin/bash
# backup-to-nas.sh - Nyx daily backup to Terramaster NAS via rsync daemon
#
# Sends Telegram alert on failure. Runs at 3:30am daily (after Dropbox backup).
#
# Prerequisites:
#   - ~/.rsync-nas-password with rsync password (chmod 600)
#   - NAS rsync daemon enabled on port 873
#   - Tailscale connected to NAS at 100.98.9.111
#
# Usage:
#   ./backup-to-nas.sh              # Normal backup
#   ./backup-to-nas.sh --dry-run    # Show what would be synced
#   ./backup-to-nas.sh --test       # Test connectivity only

set -euo pipefail

# ============================================
# Environment Setup (for cron)
# ============================================

# Source nix profile for nix-managed tools
if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"

# ============================================
# Configuration
# ============================================

LOG_FILE="$HOME/backup-nas.log"
RSYNC_USER="rsync-user"
RSYNC_HOST="100.98.9.111"
RSYNC_MODULE="Backup"
RSYNC_PASSWORD_FILE="$HOME/.rsync-nas-password"
TELEGRAM_TOKEN_FILE="$HOME/.openclaw/runtime/telegram-bot-token"
TELEGRAM_CHAT_ID="8332440542"

# Excludes for clawd
CLAWD_EXCLUDES=(
    ".git"
    ".venv"
    "__pycache__"
    "node_modules"
    ".mypy_cache"
    "*.pyc"
    ".pytest_cache"
)

# Excludes for openclaw
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
    msg="*Nyx Backup Failed*
Backup to NAS failed at $(date '+%Y-%m-%d %H:%M')
Check ~/backup-nas.log for details"
    log "ERROR: Backup failed"
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

# ============================================
# Backup Functions
# ============================================

build_excludes() {
    local -n excludes=$1
    local args=""
    for exclude in "${excludes[@]}"; do
        args+=" --exclude='$exclude'"
    done
    echo "$args"
}

sync_clawd() {
    local src="$HOME/clawd/"
    local dest="rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/nyx/clawd/"

    if [[ ! -d "$src" ]]; then
        log "WARN: Source directory does not exist: $src"
        return 0
    fi

    log "Syncing $src to NAS..."

    local rsync_opts="-avz --delete --password-file=$RSYNC_PASSWORD_FILE"

    for exclude in "${CLAWD_EXCLUDES[@]}"; do
        rsync_opts+=" --exclude=$exclude"
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        rsync_opts+=" --dry-run"
    fi

    # shellcheck disable=SC2086
    rsync $rsync_opts "$src" "$dest" 2>&1 | tee -a "$LOG_FILE"

    log "Sync of clawd complete"
}

sync_openclaw() {
    local src="$HOME/.openclaw/"
    local dest="rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/nyx/openclaw/"

    if [[ ! -d "$src" ]]; then
        log "WARN: Source directory does not exist: $src"
        return 0
    fi

    log "Syncing $src to NAS..."

    local rsync_opts="-avz --delete --password-file=$RSYNC_PASSWORD_FILE"

    for exclude in "${OPENCLAW_EXCLUDES[@]}"; do
        rsync_opts+=" --exclude=$exclude"
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        rsync_opts+=" --dry-run"
    fi

    # shellcheck disable=SC2086
    rsync $rsync_opts "$src" "$dest" 2>&1 | tee -a "$LOG_FILE"

    log "Sync of openclaw complete"
}

sync_beszel() {
    local src="$HOME/.beszel/"
    local dest="rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/nyx/beszel/"

    if [[ ! -d "$src" ]]; then
        log "WARN: Source directory does not exist: $src"
        return 0
    fi

    log "Syncing $src to NAS..."

    local rsync_opts="-avz --delete --password-file=$RSYNC_PASSWORD_FILE"

    if [[ $DRY_RUN -eq 1 ]]; then
        rsync_opts+=" --dry-run"
    fi

    # shellcheck disable=SC2086
    rsync $rsync_opts "$src" "$dest" 2>&1 | tee -a "$LOG_FILE"

    log "Sync of beszel complete"
}

sync_uptime_kuma() {
    local src="$HOME/.uptime-kuma/data/"
    local dest="rsync://${RSYNC_USER}@${RSYNC_HOST}/${RSYNC_MODULE}/nyx/uptime-kuma/"

    if [[ ! -d "$src" ]]; then
        log "WARN: Source directory does not exist: $src"
        return 0
    fi

    log "Syncing $src to NAS..."

    local rsync_opts="-avz --delete --password-file=$RSYNC_PASSWORD_FILE"

    if [[ $DRY_RUN -eq 1 ]]; then
        rsync_opts+=" --dry-run"
    fi

    # shellcheck disable=SC2086
    rsync $rsync_opts "$src" "$dest" 2>&1 | tee -a "$LOG_FILE"

    log "Sync of uptime-kuma complete"
}

# ============================================
# Main
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Backup Nyx workspace to Terramaster NAS via rsync daemon.

OPTIONS:
    --dry-run    Show what would be transferred without making changes
    --test       Test connectivity only
    -h, --help   Show this help

EXAMPLES:
    $(basename "$0")              # Run backup
    $(basename "$0") --dry-run    # Preview changes
    $(basename "$0") --test       # Test NAS connectivity
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
    log "Starting NAS backup"
    [[ $DRY_RUN -eq 1 ]] && log "DRY-RUN MODE - no changes will be made"

    # Prerequisites check
    if ! check_prerequisites; then
        send_telegram "*Nyx Backup Failed*
Prerequisites check failed. Check ~/backup-nas.log"
        exit 1
    fi

    # Set error trap after prerequisites (to avoid spam on config issues)
    trap on_error ERR

    # Connectivity check
    if ! check_nas_reachable; then
        send_telegram "*Nyx Backup Failed*
Cannot reach NAS via Tailscale at $RSYNC_HOST"
        exit 1
    fi

    # Test rsync connection
    if ! test_rsync_connection; then
        send_telegram "*Nyx Backup Failed*
Rsync connection test failed"
        exit 1
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

    # Run backups
    sync_clawd
    sync_openclaw
    sync_beszel
    sync_uptime_kuma

    log "NAS backup completed successfully"
    log "========================================"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo ""
        echo "Dry-run complete. Run without --dry-run to perform actual backup."
    else
        send_telegram "✓ Nyx NAS backup completed"
    fi
}

main "$@"
