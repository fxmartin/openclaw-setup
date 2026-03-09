#!/bin/bash
# ABOUTME: Healthcheck for openclaw gateway with auto-repair capability.
# ABOUTME: Runs via cron every 15 min; checks service, node_modules, and gateway process.
#
# Checks:
#   1. openclaw systemd service is active (not crash-looping)
#   2. Critical node_modules dependencies are present
#   3. Gateway process is actually running (not just systemd restart loop)
#
# Sends Telegram alert on failure. Designed for cron (every 15 min).
#
# Usage:
#   ./healthcheck-openclaw.sh           # Normal check (alerts on failure)
#   ./healthcheck-openclaw.sh --quiet   # Exit code only, no Telegram
#   ./healthcheck-openclaw.sh --fix     # Attempt auto-repair + alert

set -euo pipefail

# ============================================
# Environment Setup (for cron)
# ============================================

if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"

# ============================================
# Configuration
# ============================================

OPENCLAW_DIR="$HOME/openclaw-git"
TELEGRAM_TOKEN_FILE="$HOME/.openclaw/runtime/telegram-bot-token"
TELEGRAM_CHAT_ID="8332440542"
LOG_FILE="$HOME/healthcheck.log"
STATE_FILE="/tmp/openclaw-healthcheck-alerted"

# Critical packages that must exist in node_modules
REQUIRED_PACKAGES=(
    "proper-lockfile"
    "ajv"
    "chalk"
)

QUIET=0
AUTO_FIX=0

# ============================================
# Helpers
# ============================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

get_telegram_token() {
    if [[ -f "$TELEGRAM_TOKEN_FILE" ]]; then
        cat "$TELEGRAM_TOKEN_FILE"
    fi
}

send_telegram() {
    [[ $QUIET -eq 1 ]] && return
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

# Only alert once per issue (reset on recovery)
should_alert() {
    [[ ! -f "$STATE_FILE" ]]
}

mark_alerted() {
    touch "$STATE_FILE"
}

clear_alert() {
    rm -f "$STATE_FILE"
}

# ============================================
# Health Checks
# ============================================

check_service_active() {
    if systemctl is-active --quiet openclaw; then
        return 0
    fi
    return 1
}

check_service_crash_loop() {
    local restart_count
    restart_count=$(systemctl show openclaw --property=NRestarts --value 2>/dev/null || echo "0")
    # If service has restarted more than 5 times, it's likely crash-looping
    if [[ "$restart_count" -gt 5 ]]; then
        echo "$restart_count"
        return 1
    fi
    return 0
}

check_node_modules() {
    local missing=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if [[ ! -d "$OPENCLAW_DIR/node_modules/$pkg" ]]; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "${missing[*]}"
        return 1
    fi
    return 0
}

check_gateway_process() {
    if pgrep -f "openclaw gateway run" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ============================================
# Auto-repair
# ============================================

attempt_fix() {
    log "Attempting auto-repair: stopping service, reinstalling node_modules"

    # Stop the service first to prevent the race condition where systemd's
    # restart loop reads from node_modules while npm install is writing to it.
    log "Stopping openclaw service before npm install"
    sudo systemctl stop openclaw

    cd "$OPENCLAW_DIR"

    if rm -rf node_modules && npm install 2>&1 | tail -5 | tee -a "$LOG_FILE"; then
        log "npm install succeeded, starting openclaw service"
        sudo systemctl start openclaw
        sleep 5

        if check_service_active && check_gateway_process; then
            log "Auto-repair successful"
            return 0
        fi
    else
        log "npm install failed, starting openclaw service anyway"
        sudo systemctl start openclaw
    fi

    log "Auto-repair failed"
    return 1
}

# ============================================
# Main
# ============================================

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --fix)   AUTO_FIX=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--quiet|--fix]"
            echo "  --quiet  Exit code only, no Telegram alerts"
            echo "  --fix    Attempt auto-repair on failure"
            exit 0
            ;;
    esac
done

failures=()

# Check 1: node_modules integrity
if missing=$(check_node_modules); then
    : # ok
else
    failures+=("Missing npm packages: $missing")
    log "FAIL: Missing npm packages: $missing"
fi

# Check 2: systemd service active
if ! check_service_active; then
    failures+=("openclaw service is not active")
    log "FAIL: openclaw service is not active"
fi

# Check 3: gateway process running
if ! check_gateway_process; then
    failures+=("No openclaw gateway process found")
    log "FAIL: No openclaw gateway process found"
fi

# Check 4: crash-loop detection
if restart_count=$(check_service_crash_loop); then
    : # ok
else
    failures+=("Service crash-looping (${restart_count} restarts)")
    log "FAIL: Service crash-looping (${restart_count} restarts)"
fi

# All healthy
if [[ ${#failures[@]} -eq 0 ]]; then
    clear_alert
    exit 0
fi

# Something is wrong
log "Healthcheck failed: ${failures[*]}"

# Try auto-fix if requested
if [[ $AUTO_FIX -eq 1 ]]; then
    if attempt_fix; then
        send_telegram "⚠ *Nyx Auto-Repair*
Detected: ${failures[*]}
Action: Ran npm install + service restart
Result: ✓ Recovered"
        clear_alert
        exit 0
    fi
fi

# Alert (only once per incident)
if should_alert; then
    send_telegram "🔴 *Nyx Healthcheck Failed*
$(printf '%s\n' "${failures[@]}" | sed 's/^/• /')

Server: nyx
Time: $(date '+%Y-%m-%d %H:%M')
Run \`healthcheck-openclaw.sh --fix\` to attempt repair"
    mark_alerted
fi

exit 1
