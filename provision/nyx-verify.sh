#!/usr/bin/env bash
# nyx-verify.sh - Post-install verification for Nyx server
#
# Usage:
#   ./nyx-verify.sh           # Run locally on Nyx server
#   ./nyx-verify.sh --remote nyx  # Run checks against remote server
#
# Verifies all components are correctly installed and configured.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# Configuration
TARGET_USER="fx"
TARGET_HOME="/home/${TARGET_USER}"
REMOTE_HOST=""
VERBOSE=0

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# ============================================
# Usage
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Verify Nyx server configuration.

OPTIONS:
    -r, --remote HOST   Run verification against remote host
    -v, --verbose       Verbose output
    -h, --help          Show this help message

EXAMPLES:
    # Run locally on Nyx server
    ./nyx-verify.sh

    # Run against remote server
    ./nyx-verify.sh --remote nyx
    ./nyx-verify.sh --remote root@1.2.3.4
EOF
}

# ============================================
# Argument Parsing
# ============================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--remote)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                DEBUG=1
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
}

# ============================================
# Check Helpers
# ============================================

# Run command locally or remotely
run_check() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes "$REMOTE_HOST" "$@"
    else
        eval "$@"
    fi
}

# Record pass/fail
check_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

check_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

check_warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++))
}

check_skip() {
    echo -e "  ${CYAN}[SKIP]${NC} $1"
}

# ============================================
# Verification Checks
# ============================================

verify_age_key() {
    log_step "AGE Private Key"

    if run_check "sudo test -f /root/.config/sops/age/keys.txt"; then
        check_pass "AGE key file exists"
    else
        check_fail "AGE key file not found at /root/.config/sops/age/keys.txt"
        return
    fi

    # Check permissions
    local perms
    perms=$(run_check "sudo stat -c '%a' /root/.config/sops/age/keys.txt")
    if [[ "$perms" == "600" ]]; then
        check_pass "AGE key has correct permissions (600)"
    else
        check_fail "AGE key has wrong permissions: $perms (should be 600)"
    fi
}

verify_sops() {
    log_step "SOPS Configuration"

    # Check SOPS is installed
    if run_check "command -v sops &>/dev/null"; then
        local version
        version=$(run_check "sops --version 2>&1 | head -1")
        check_pass "SOPS installed: $version"
    else
        check_fail "SOPS not installed"
        return
    fi

    # Check encrypted config exists
    if run_check "test -f ${TARGET_HOME}/.openclaw/openclaw.json.enc"; then
        check_pass "Encrypted config exists"
    else
        check_fail "Encrypted config not found: ${TARGET_HOME}/.openclaw/openclaw.json.enc"
        return
    fi

    # Try to decrypt (verify key works)
    if run_check "sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt sops -d ${TARGET_HOME}/.openclaw/openclaw.json.enc >/dev/null 2>&1"; then
        check_pass "SOPS can decrypt config"
    else
        check_fail "SOPS cannot decrypt config (key mismatch?)"
    fi
}

verify_tmpfs() {
    log_step "tmpfs Mount (Runtime Secrets)"

    local runtime_dir="${TARGET_HOME}/.openclaw/runtime"

    # Check if mount unit exists
    if run_check "test -f /etc/systemd/system/home-fx-.openclaw-runtime.mount"; then
        check_pass "tmpfs mount unit exists"
    else
        check_warn "tmpfs mount unit not found (may use inline mounting)"
    fi

    # Check if mounted
    if run_check "mountpoint -q $runtime_dir 2>/dev/null"; then
        local mount_type
        mount_type=$(run_check "df -T $runtime_dir | tail -1 | awk '{print \$2}'")
        if [[ "$mount_type" == "tmpfs" ]]; then
            check_pass "Runtime directory mounted as tmpfs"
        else
            check_fail "Runtime directory not tmpfs: $mount_type"
        fi
    else
        check_warn "Runtime directory not currently mounted (will mount on service start)"
    fi
}

verify_openclaw_service() {
    log_step "Openclaw Service"

    # Check service file exists
    if run_check "test -f /etc/systemd/system/openclaw.service"; then
        check_pass "Service file exists"
    else
        check_fail "Service file not found"
        return
    fi

    # Check service status
    local status
    status=$(run_check "systemctl is-active openclaw.service 2>/dev/null" || true)

    case "$status" in
        active)
            check_pass "Service is running"
            ;;
        inactive)
            check_warn "Service is not running"
            ;;
        failed)
            check_fail "Service is in failed state"
            ;;
        *)
            check_warn "Service status: $status"
            ;;
    esac

    # Check if enabled
    if run_check "systemctl is-enabled openclaw.service &>/dev/null"; then
        check_pass "Service is enabled (will start on boot)"
    else
        check_warn "Service is not enabled"
    fi
}

verify_dropbox() {
    log_step "Dropbox Backup (rclone)"

    # Check rclone installed
    if run_check "command -v rclone &>/dev/null"; then
        check_pass "rclone installed"
    else
        check_fail "rclone not installed"
        return
    fi

    # Check config exists
    if run_check "test -f ${TARGET_HOME}/.config/rclone/rclone.conf"; then
        check_pass "rclone config exists"
    else
        check_fail "rclone config not found"
        return
    fi

    # Check dropbox remote configured
    if run_check "su - $TARGET_USER -c 'rclone listremotes' 2>/dev/null | grep -q 'dropbox:'"; then
        check_pass "Dropbox remote configured"

        # Try to list backup
        if run_check "su - $TARGET_USER -c 'rclone lsf dropbox:nyx-backup/ 2>/dev/null' | head -1" &>/dev/null; then
            check_pass "Dropbox backup accessible"
        else
            check_warn "Cannot access dropbox:nyx-backup/"
        fi
    else
        check_warn "Dropbox remote not configured"
    fi
}

verify_tailscale() {
    log_step "Tailscale"

    # Check tailscale installed
    if run_check "command -v tailscale &>/dev/null"; then
        check_pass "Tailscale installed"
    else
        check_fail "Tailscale not installed"
        return
    fi

    # Check connected
    if run_check "tailscale status &>/dev/null"; then
        local ip
        ip=$(run_check "tailscale ip -4 2>/dev/null" || echo "unknown")
        check_pass "Tailscale connected (IP: $ip)"
    else
        check_fail "Tailscale not connected"
    fi
}

verify_security() {
    log_step "Security Stack"

    # UFW
    if run_check "command -v ufw &>/dev/null"; then
        local ufw_status
        ufw_status=$(run_check "sudo ufw status" 2>/dev/null || echo "unknown")
        if echo "$ufw_status" | grep -q "Status: active"; then
            check_pass "UFW firewall active"
        else
            check_fail "UFW firewall not active"
        fi
    else
        check_fail "UFW not installed"
    fi

    # Fail2ban
    if run_check "command -v fail2ban-client &>/dev/null"; then
        if run_check "systemctl is-active fail2ban &>/dev/null"; then
            local jails
            jails=$(run_check "sudo fail2ban-client status 2>/dev/null | grep 'Jail list' | cut -d: -f2" || echo "none")
            check_pass "Fail2ban active (jails:$jails)"
        else
            check_fail "Fail2ban not running"
        fi
    else
        check_fail "Fail2ban not installed"
    fi

    # SSH hardening
    if run_check "test -f /etc/ssh/sshd_config.d/99-hardening.conf"; then
        check_pass "SSH hardening config installed"
    else
        check_warn "SSH hardening config not found"
    fi

    # rkhunter
    if run_check "command -v rkhunter &>/dev/null"; then
        check_pass "rkhunter installed"
    else
        check_warn "rkhunter not installed"
    fi
}

verify_software() {
    log_step "Software Stack"

    # Node.js
    if run_check "command -v node &>/dev/null"; then
        local version
        version=$(run_check "node --version")
        check_pass "Node.js installed: $version"
    else
        check_fail "Node.js not installed"
    fi

    # openclaw
    if run_check "su - $TARGET_USER -c 'command -v openclaw' &>/dev/null"; then
        local version
        version=$(run_check "su - $TARGET_USER -c 'openclaw --version 2>/dev/null'" || echo "unknown")
        check_pass "openclaw installed: $version"
    else
        check_fail "openclaw not installed"
    fi

    # age
    if run_check "command -v age &>/dev/null"; then
        check_pass "age installed"
    else
        check_fail "age not installed"
    fi

    # gh
    if run_check "command -v gh &>/dev/null"; then
        check_pass "GitHub CLI installed"
    else
        check_warn "GitHub CLI not installed"
    fi
}

verify_workspace() {
    log_step "Workspace"

    local clawd_dir="${TARGET_HOME}/clawd"

    if run_check "test -d $clawd_dir"; then
        check_pass "Workspace directory exists: $clawd_dir"

        # Check for key files
        local key_files=("IDENTITY.md" "SOUL.md" "MEMORY.md")
        for file in "${key_files[@]}"; do
            if run_check "test -f ${clawd_dir}/${file}"; then
                check_pass "Found: $file"
            else
                check_warn "Missing: $file"
            fi
        done
    else
        check_fail "Workspace directory not found: $clawd_dir"
    fi
}

# ============================================
# Summary
# ============================================

print_summary() {
    separator
    echo ""
    echo -e "${BOLD}Verification Summary${NC}"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}   $PASSED"
    echo -e "  ${RED}Failed:${NC}   $FAILED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo ""

    if [[ $FAILED -eq 0 ]]; then
        log_success "All critical checks passed!"
        return 0
    else
        log_error "$FAILED critical checks failed"
        return 1
    fi
}

# ============================================
# Main
# ============================================

main() {
    parse_args "$@"

    banner "Nyx Server Verification"

    if [[ -n "$REMOTE_HOST" ]]; then
        log_info "Running verification against: $REMOTE_HOST"
    else
        log_info "Running local verification"
    fi

    echo ""

    # Run all checks
    verify_age_key
    verify_sops
    verify_tmpfs
    verify_openclaw_service
    verify_dropbox
    verify_tailscale
    verify_security
    verify_software
    verify_workspace

    # Print summary
    print_summary
}

main "$@"
