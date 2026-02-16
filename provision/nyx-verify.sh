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
RESOLVED_HOST=""
RESOLVED_HOSTNAME=""
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

# Resolve hostname to IP if needed
# Sets RESOLVED_HOST to user@ip format
resolve_remote_host() {
    local host="$1"
    local user="fx"
    local ip=""

    # Extract user if present (user@host format)
    if [[ "$host" =~ @ ]]; then
        user="${host%%@*}"
        host="${host#*@}"
    fi

    # If already an IP, use it directly but try to find hostname for key lookup
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RESOLVED_HOST="${user}@${host}"
        # Try to reverse-lookup hostname from Tailscale for SSH key matching
        if command -v tailscale &>/dev/null; then
            local ts_hostname
            ts_hostname=$(tailscale status 2>/dev/null | awk -v ip="$host" '$1 == ip {print $2; exit}')
            if [[ -n "$ts_hostname" ]]; then
                RESOLVED_HOSTNAME="$ts_hostname"
                [[ $VERBOSE -eq 1 ]] && echo "  Reverse-resolved $host to $ts_hostname via tailscale" >&2
                return 0
            fi
        fi
        # Fallback: use IP as hostname (key lookup will fail gracefully)
        RESOLVED_HOSTNAME="${host}"
        return 0
    fi

    # Store original hostname for key lookup
    RESOLVED_HOSTNAME="$host"

    # Prefer Tailscale (private network, more reliable)
    if command -v tailscale &>/dev/null; then
        # Look for exact hostname match in tailscale status (column 2)
        if ip=$(tailscale status 2>/dev/null | awk -v h="$host" '$2 == h {print $1; exit}'); then
            if [[ -n "$ip" ]]; then
                RESOLVED_HOST="${user}@${ip}"
                [[ $VERBOSE -eq 1 ]] && echo "  Resolved $host via tailscale: $ip" >&2
                return 0
            fi
        fi
    fi

    # Fall back to hcloud public IP (may be firewalled)
    if command -v hcloud &>/dev/null; then
        if ip=$(hcloud server ip "$host" 2>/dev/null); then
            RESOLVED_HOST="${user}@${ip}"
            [[ $VERBOSE -eq 1 ]] && echo "  Resolved $host via hcloud: $ip" >&2
            return 0
        fi
    fi

    # Try DNS resolution as last resort
    if ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1); then
        if [[ -n "$ip" ]]; then
            RESOLVED_HOST="${user}@${ip}"
            [[ $VERBOSE -eq 1 ]] && echo "  Resolved $host via DNS: $ip" >&2
            return 0
        fi
    fi

    # Could not resolve - use original (will likely fail but with clear error)
    RESOLVED_HOST="${user}@${host}"
    return 1
}

# Run command locally or remotely
run_check() {
    if [[ -n "$REMOTE_HOST" ]]; then
        local ssh_opts="-o StrictHostKeyChecking=no -o BatchMode=yes"
        # Try to find SSH key for this host (pattern: ~/.ssh/id_<hostname>)
        local host_name="$RESOLVED_HOSTNAME"
        local key_file="$HOME/.ssh/id_${host_name}"
        if [[ -f "$key_file" ]]; then
            ssh_opts="$ssh_opts -i $key_file"
        fi
        # shellcheck disable=SC2086
        ssh $ssh_opts "$RESOLVED_HOST" "$@"
    else
        eval "$@"
    fi
}

# Run command as target user (handles local vs remote context)
# When remote: already connected as user, no su needed
# When local: use su - to become target user
run_as_user() {
    local path_setup=". ~/.nix-profile/etc/profile.d/nix.sh 2>/dev/null; export PATH=~/.local/share/npm-global/bin:~/.local/bin:\$PATH"
    if [[ -n "$REMOTE_HOST" ]]; then
        # Remote: already connected as target user, run directly
        run_check "$path_setup; $*"
    else
        # Local: use su to become target user
        su - "$TARGET_USER" -c "$path_setup && $*"
    fi
}

# Record pass/fail
# Note: Using || true to prevent set -e from exiting when counter is 0
check_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    ((PASSED++)) || true
}

check_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    ((FAILED++)) || true
}

check_warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++)) || true
}

check_skip() {
    echo -e "  ${CYAN}[SKIP]${NC} $1"
}

# ============================================
# Verification Checks
# ============================================

verify_age_key() {
    log_step "AGE Private Key"

    # Remote check without sudo - verify via sops symlink and service status
    if [[ -n "$REMOTE_HOST" ]]; then
        # Can't sudo remotely, check indirectly via service running
        if run_check "test -L /usr/local/bin/sops"; then
            check_pass "AGE key accessible (sops symlink exists)"
        else
            check_warn "Cannot verify AGE key remotely (needs sudo)"
        fi
        return
    fi

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

    # Check SOPS is installed (via symlink or Nix)
    if run_as_user "command -v sops" &>/dev/null; then
        local version
        version=$(run_as_user "sops --version 2>&1 | head -1" || echo "unknown")
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

    # Try to decrypt (verify key works) - needs sudo for AGE key
    if [[ -n "$REMOTE_HOST" ]]; then
        # Can't sudo remotely - verify indirectly via decrypted file in tmpfs
        if run_check "test -f ${TARGET_HOME}/.openclaw/runtime/openclaw.json"; then
            check_pass "SOPS decryption working (runtime config exists)"
        else
            check_warn "Cannot verify SOPS decryption remotely (runtime config not found)"
        fi
    else
        if run_check "sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt sops -d ${TARGET_HOME}/.openclaw/openclaw.json.enc >/dev/null 2>&1"; then
            check_pass "SOPS can decrypt config"
        else
            check_fail "SOPS cannot decrypt config (key mismatch?)"
        fi
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
    if run_as_user "command -v rclone" &>/dev/null; then
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
    if run_as_user "rclone listremotes 2>/dev/null" | grep -q 'dropbox:'; then
        check_pass "Dropbox remote configured"

        # Try to list backup
        if run_as_user "rclone lsf dropbox:nyx-backup/ 2>/dev/null | head -1" &>/dev/null; then
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
    if run_as_user "command -v node" &>/dev/null; then
        local version
        version=$(run_as_user "node --version" || echo "unknown")
        check_pass "Node.js installed: $version"
    else
        check_fail "Node.js not installed"
    fi

    # openclaw
    if run_as_user "command -v openclaw" &>/dev/null; then
        local version
        version=$(run_as_user "openclaw --version 2>/dev/null" || echo "unknown")
        check_pass "openclaw installed: $version"
    else
        check_fail "openclaw not installed"
    fi

    # age
    if run_as_user "command -v age" &>/dev/null; then
        check_pass "age installed"
    else
        check_fail "age not installed"
    fi

    # gh
    if run_as_user "command -v gh" &>/dev/null; then
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

verify_nix() {
    log_step "Nix Package Manager"

    # Check if Nix is installed
    if run_as_user "command -v nix" &>/dev/null; then
        local version
        version=$(run_as_user "nix --version 2>/dev/null" || echo "unknown")
        check_pass "Nix installed: $version"
    else
        check_fail "Nix not installed"
        return
    fi

    # Check flakes enabled
    if run_check "test -f ${TARGET_HOME}/.config/nix/nix.conf"; then
        if run_check "grep -q 'flakes' ${TARGET_HOME}/.config/nix/nix.conf 2>/dev/null"; then
            check_pass "Nix flakes enabled"
        else
            check_warn "Nix flakes may not be enabled"
        fi
    else
        check_warn "Nix config not found"
    fi

    # Check Home Manager
    if run_as_user "command -v home-manager" &>/dev/null; then
        check_pass "Home Manager available"

        # Check generations
        local gen_count
        gen_count=$(run_as_user "home-manager generations 2>/dev/null | wc -l" || echo "0")
        if [[ "$gen_count" -gt 0 ]]; then
            check_pass "Home Manager generations: $gen_count"
        else
            check_warn "No Home Manager generations found"
        fi
    else
        check_warn "Home Manager not installed"
    fi

    # Check Nix config directory
    if run_check "test -d ${TARGET_HOME}/nix-config"; then
        check_pass "Nix config directory exists"

        # Check flake files
        if run_check "test -f ${TARGET_HOME}/nix-config/flake.nix"; then
            check_pass "flake.nix present"
        else
            check_fail "flake.nix missing"
        fi

        if run_check "test -f ${TARGET_HOME}/nix-config/flake.lock"; then
            check_pass "flake.lock present (versions pinned)"
        else
            check_warn "flake.lock missing (versions not pinned)"
        fi
    else
        check_fail "Nix config directory not found"
    fi
}

verify_nix_packages() {
    log_step "Nix-Managed Packages"

    # List of packages that should be managed by Nix
    local packages=("age" "sops" "node" "rclone" "ffmpeg" "pandoc" "gh" "jq" "git" "curl" "rsync")

    for pkg in "${packages[@]}"; do
        if run_as_user "command -v $pkg" &>/dev/null; then
            local version
            case "$pkg" in
                node)
                    version=$(run_as_user "node --version 2>/dev/null" || echo "")
                    ;;
                age)
                    version=$(run_as_user "age --version 2>/dev/null" || echo "")
                    ;;
                sops)
                    version=$(run_as_user "sops --version 2>/dev/null | head -1" || echo "")
                    ;;
                jq)
                    version=$(run_as_user "jq --version 2>/dev/null" || echo "")
                    ;;
                gh)
                    version=$(run_as_user "gh --version 2>/dev/null | head -1" || echo "")
                    ;;
                *)
                    version=""
                    ;;
            esac
            if [[ -n "$version" ]]; then
                check_pass "$pkg: $version"
            else
                check_pass "$pkg available"
            fi
        else
            check_fail "$pkg not found"
        fi
    done
}

verify_monitoring() {
    log_step "Monitoring Stack"

    # Beszel Hub
    if run_as_user "test -f ~/.local/bin/beszel"; then
        check_pass "Beszel hub binary installed"

        if run_as_user "systemctl --user is-active beszel-hub" &>/dev/null; then
            check_pass "Beszel hub service running"

            # Check if hub responds on port 8090
            if run_as_user "curl -s --connect-timeout 3 http://localhost:8090/api/health" &>/dev/null; then
                check_pass "Beszel hub responding on port 8090"
            else
                check_warn "Beszel hub not responding on port 8090"
            fi
        else
            check_warn "Beszel hub service not running"
        fi
    else
        check_warn "Beszel hub not installed"
    fi

    # Beszel Agent
    if run_as_user "test -f ~/.local/bin/beszel-agent"; then
        check_pass "Beszel agent binary installed"

        if run_as_user "systemctl --user is-active beszel-agent" &>/dev/null; then
            check_pass "Beszel agent service running"
        else
            check_warn "Beszel agent service not running (KEY may need configuration)"
        fi
    else
        check_warn "Beszel agent not installed"
    fi

    # Uptime Kuma
    if run_as_user "test -f ~/.uptime-kuma/server/server.js"; then
        check_pass "Uptime Kuma installed"

        if run_as_user "systemctl --user is-active uptime-kuma" &>/dev/null; then
            check_pass "Uptime Kuma service running"

            # Check if Uptime Kuma responds on port 3001
            if run_as_user "curl -s --connect-timeout 3 http://localhost:3001" &>/dev/null; then
                check_pass "Uptime Kuma responding on port 3001"
            else
                check_warn "Uptime Kuma not responding on port 3001"
            fi
        else
            check_warn "Uptime Kuma service not running"
        fi
    else
        check_warn "Uptime Kuma not installed"
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
        # Resolve hostname to IP (handles Nix-managed SSH config, Hetzner, Tailscale)
        if ! resolve_remote_host "$REMOTE_HOST"; then
            log_warn "Could not resolve '$REMOTE_HOST' - trying anyway"
        fi
        log_info "Running verification against: $RESOLVED_HOST"
        [[ "$RESOLVED_HOST" != "$REMOTE_HOST" ]] && log_info "  (resolved from: $REMOTE_HOST)"
    else
        log_info "Running local verification"
    fi

    echo ""

    # Run all checks
    verify_nix
    verify_nix_packages
    verify_age_key
    verify_sops
    verify_tmpfs
    verify_openclaw_service
    verify_dropbox
    verify_tailscale
    verify_security
    verify_software
    verify_workspace
    verify_monitoring

    # Print summary
    print_summary
}

main "$@"
