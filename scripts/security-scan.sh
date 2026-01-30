#!/bin/bash
# security-scan.sh - Nyx weekly security scan
#
# Runs rkhunter rootkit check, checks fail2ban status, and reviews
# failed SSH attempts. Sends Telegram notification on completion.
# Runs at 4:00am every Sunday.
#
# Prerequisites:
#   - rkhunter installed
#   - fail2ban installed
#   - Telegram bot token in ~/.openclaw/runtime/telegram-bot-token
#
# Usage:
#   ./security-scan.sh              # Run full scan
#   ./security-scan.sh --summary    # Just show summary of last scan

set -euo pipefail

# ============================================
# Configuration
# ============================================

LOG_FILE="$HOME/security-scan.log"
TELEGRAM_TOKEN_FILE="$HOME/.openclaw/runtime/telegram-bot-token"
TELEGRAM_CHAT_ID="8332440542"

# ============================================
# Helpers
# ============================================

SUMMARY_ONLY=0

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
    log "ERROR: Security scan failed"
    send_telegram "✗ Nyx security scan failed - check ~/security-scan.log"
    exit 1
}

# ============================================
# Scan Functions
# ============================================

run_rkhunter() {
    log "Running rkhunter rootkit check..."

    # Update rkhunter database first
    if sudo rkhunter --update --nocolors &>/dev/null; then
        log "rkhunter database updated"
    fi

    # Run check (skip-keypress for non-interactive, report-warnings-only to reduce noise)
    if sudo rkhunter --check --skip-keypress --report-warnings-only --nocolors >> "$LOG_FILE" 2>&1; then
        log "rkhunter: No warnings"
        return 0
    else
        local warnings
        warnings=$(grep -c "Warning:" "$LOG_FILE" 2>/dev/null || echo "0")
        log "rkhunter: $warnings warning(s) found"
        return 0  # Don't fail on warnings, just report
    fi
}

check_fail2ban() {
    log "Checking fail2ban status..."

    if ! command -v fail2ban-client &>/dev/null; then
        log "WARN: fail2ban not installed"
        return 0
    fi

    # Get jail status
    echo "--- Fail2ban Status ---" >> "$LOG_FILE"
    sudo fail2ban-client status >> "$LOG_FILE" 2>&1 || true

    # Get sshd jail details
    if sudo fail2ban-client status sshd &>/dev/null; then
        echo "--- SSHD Jail ---" >> "$LOG_FILE"
        sudo fail2ban-client status sshd >> "$LOG_FILE" 2>&1 || true

        # Count banned IPs
        local banned
        banned=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -oE "[0-9]+" || echo "0")
        log "fail2ban: $banned IP(s) currently banned"
    fi
}

check_ssh_failures() {
    log "Checking SSH authentication failures..."

    echo "--- Recent Failed SSH Attempts ---" >> "$LOG_FILE"

    local failed_count=0
    if [[ -f /var/log/auth.log ]]; then
        # Count failed password attempts in last 7 days
        failed_count=$(sudo grep "Failed password" /var/log/auth.log 2>/dev/null | wc -l || echo "0")

        # Show last 20 failed attempts
        sudo grep "Failed password" /var/log/auth.log 2>/dev/null | tail -20 >> "$LOG_FILE" || true
    fi

    log "SSH: $failed_count failed password attempt(s) in auth.log"
}

check_listening_ports() {
    log "Checking listening ports..."

    echo "--- Listening Ports ---" >> "$LOG_FILE"
    sudo ss -tulnp >> "$LOG_FILE" 2>&1 || sudo netstat -tulnp >> "$LOG_FILE" 2>&1 || true
}

show_summary() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "No scan log found at $LOG_FILE"
        exit 0
    fi

    echo "=== Last Security Scan Summary ==="
    echo ""

    # Show last scan header
    grep -E "^=|Starting|completed" "$LOG_FILE" | tail -10

    echo ""
    echo "=== Warnings ==="
    grep -i "warning\|banned\|failed" "$LOG_FILE" | tail -20 || echo "(none)"

    echo ""
    echo "Full log: $LOG_FILE"
}

# ============================================
# Main
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run weekly security scan on Nyx server.

OPTIONS:
    --summary   Show summary of last scan
    -h, --help  Show this help

EXAMPLES:
    $(basename "$0")           # Run full scan
    $(basename "$0") --summary # View last scan results
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --summary)
                SUMMARY_ONLY=1
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

    # Summary mode - just show last scan
    if [[ $SUMMARY_ONLY -eq 1 ]]; then
        show_summary
        exit 0
    fi

    # Rotate log if too large (>10MB)
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null) -gt 10485760 ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi

    log "========================================"
    log "Starting security scan"

    # Set error trap
    trap on_error ERR

    # Run all security checks
    run_rkhunter
    check_fail2ban
    check_ssh_failures
    check_listening_ports

    log "Security scan completed"
    log "========================================"

    send_telegram "✓ Nyx security scan completed"
}

main "$@"
