#!/bin/bash
# backup-to-dropbox.sh - Nyx daily backup to Dropbox via rclone
#
# Syncs clawd workspace and openclaw config to Dropbox. Sends Telegram
# notifications on success and failure. Runs at 3:00am daily.
#
# Prerequisites:
#   - rclone configured with Dropbox remote named "dropbox"
#   - Telegram bot token in ~/.openclaw/runtime/telegram-bot-token
#
# Usage:
#   ./backup-to-dropbox.sh              # Normal backup
#   ./backup-to-dropbox.sh --dry-run    # Show what would be synced

set -euo pipefail

# ============================================
# Environment Setup (for cron)
# ============================================

# Source nix profile for rclone and other nix-managed tools
if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"

# ============================================
# Configuration
# ============================================

LOG_FILE="$HOME/backup.log"
TELEGRAM_TOKEN_FILE="$HOME/.openclaw/runtime/telegram-bot-token"
TELEGRAM_CHAT_ID="8332440542"

# Excludes for clawd
CLAWD_EXCLUDES=(
    ".git/**"
    ".venv/**"
    "__pycache__/**"
    "node_modules/**"
    ".mypy_cache/**"
    "*.pyc"
    ".pytest_cache/**"
)

# Excludes for openclaw
OPENCLAW_EXCLUDES=(
    "telegram/**"
    "agents/*/sessions/**"
    "runtime/**"
    "*.log"
)

# ============================================
# Helpers
# ============================================

DRY_RUN=0

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
            -d text="$message" > /dev/null 2>&1 || true
    fi
}

on_error() {
    log "ERROR: Dropbox backup failed"
    send_telegram "✗ Nyx Dropbox backup failed - check ~/backup.log"
    exit 1
}

# ============================================
# Backup Functions
# ============================================

sync_clawd() {
    local src="$HOME/clawd/"
    local dest="dropbox:nyx-backup/clawd/"

    if [[ ! -d "$src" ]]; then
        log "WARN: Source directory does not exist: $src"
        return 0
    fi

    log "Syncing clawd to Dropbox..."

    local rclone_opts=""
    if [[ $DRY_RUN -eq 1 ]]; then
        rclone_opts="--dry-run -v"
    else
        rclone_opts="-q"
    fi
    
    for exclude in "${CLAWD_EXCLUDES[@]}"; do
        rclone_opts+=" --exclude=$exclude"
    done

    # shellcheck disable=SC2086
    rclone sync "$src" "$dest" $rclone_opts 2>&1 | tee -a "$LOG_FILE"

    log "Clawd sync complete"
}

sync_openclaw() {
    local src="$HOME/.openclaw/"
    local dest="dropbox:nyx-backup/openclaw/"

    if [[ ! -d "$src" ]]; then
        log "WARN: Source directory does not exist: $src"
        return 0
    fi

    log "Syncing openclaw to Dropbox..."

    local rclone_opts=""
    if [[ $DRY_RUN -eq 1 ]]; then
        rclone_opts="--dry-run -v"
    else
        rclone_opts="-q"
    fi
    
    for exclude in "${OPENCLAW_EXCLUDES[@]}"; do
        rclone_opts+=" --exclude=$exclude"
    done

    # shellcheck disable=SC2086
    rclone sync "$src" "$dest" $rclone_opts 2>&1 | tee -a "$LOG_FILE"

    log "Openclaw sync complete"
}

# ============================================
# Main
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Backup Nyx workspace to Dropbox via rclone.

OPTIONS:
    --dry-run    Show what would be transferred without making changes
    -h, --help   Show this help

EXAMPLES:
    $(basename "$0")              # Run backup
    $(basename "$0") --dry-run    # Preview changes
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
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
    log "Starting Dropbox backup"
    [[ $DRY_RUN -eq 1 ]] && log "DRY-RUN MODE - no changes will be made"

    # Check rclone is configured
    if ! rclone listremotes 2>/dev/null | grep -q "dropbox:"; then
        log "ERROR: Dropbox remote not configured in rclone"
        send_telegram "✗ Nyx Dropbox backup failed - rclone not configured"
        exit 1
    fi

    # Set error trap
    trap on_error ERR

    # Run backups
    sync_clawd
    sync_openclaw

    log "Dropbox backup completed successfully"
    log "========================================"

    if [[ $DRY_RUN -eq 0 ]]; then
        send_telegram "✓ Nyx Dropbox backup completed"
    else
        echo ""
        echo "Dry-run complete. Run without --dry-run to perform actual backup."
    fi
}

main "$@"
