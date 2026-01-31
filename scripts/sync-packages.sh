#!/bin/bash
# sync-packages.sh - Package management utility for Nyx server
#
# DEPRECATED: Package management has migrated from apt to Nix.
# This script now serves as a reference and provides Nix guidance.
#
# The following packages are now managed by Nix (via Home Manager):
#   curl, jq, git, gh, rsync, netcat, ffmpeg, pandoc, rclone, age, sops, nodejs_22
#
# Security packages remain on apt:
#   fail2ban, ufw, rkhunter, unattended-upgrades
#
# Usage:
#   ./sync-packages.sh              # Show Nix package management info
#   ./sync-packages.sh --check-apt  # Compare apt security packages

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
NYX_HOST="nyx"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# ============================================
# Main
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Package management has migrated from apt to Nix with Home Manager.

OPTIONS:
    --check-apt     Check security packages still on apt
    --status        Show Nix Home Manager status on Nyx
    -h, --help      Show this help

NIX PACKAGE MANAGEMENT:
    Most packages are now managed declaratively via Nix:

    Update packages:
      ssh $NYX_HOST '~/nix-update.sh'

    Rollback to previous version:
      ssh $NYX_HOST '~/nix-rollback.sh'

    View generations:
      ssh $NYX_HOST 'home-manager generations'

SECURITY PACKAGES (still on apt):
    fail2ban, ufw, rkhunter, unattended-upgrades

    These packages have deep systemd/kernel integration and remain on apt.
    They receive automatic security updates via unattended-upgrades.

CONFIGURATION:
    Nix config location: ~/nix-config/
    - flake.nix:    Package definitions
    - packages.nix: Home Manager configuration
    - flake.lock:   Pinned versions (reproducibility)

EOF
}

check_apt_packages() {
    log_step "Checking apt-managed security packages on Nyx..."

    local security_packages=("fail2ban" "ufw" "rkhunter" "unattended-upgrades")

    for pkg in "${security_packages[@]}"; do
        if ssh "$NYX_HOST" "dpkg -l $pkg &>/dev/null" 2>/dev/null; then
            local version
            version=$(ssh "$NYX_HOST" "dpkg -l $pkg 2>/dev/null | tail -1 | awk '{print \$3}'" 2>/dev/null || echo "unknown")
            echo -e "  ${GREEN}[OK]${NC} $pkg: $version"
        else
            echo -e "  ${RED}[MISSING]${NC} $pkg"
        fi
    done
}

show_nix_status() {
    log_step "Nix Home Manager status on Nyx..."
    echo ""

    # Check Nix installation
    if ssh "$NYX_HOST" '. ~/.nix-profile/etc/profile.d/nix.sh 2>/dev/null && command -v nix &>/dev/null' 2>/dev/null; then
        local nix_version
        nix_version=$(ssh "$NYX_HOST" '. ~/.nix-profile/etc/profile.d/nix.sh && nix --version 2>/dev/null' 2>/dev/null || echo "unknown")
        echo -e "  Nix: ${GREEN}installed${NC} ($nix_version)"
    else
        echo -e "  Nix: ${RED}not installed${NC}"
        return 1
    fi

    # Check Home Manager
    if ssh "$NYX_HOST" '. ~/.nix-profile/etc/profile.d/nix.sh && command -v home-manager &>/dev/null' 2>/dev/null; then
        local gen_count
        gen_count=$(ssh "$NYX_HOST" '. ~/.nix-profile/etc/profile.d/nix.sh && home-manager generations 2>/dev/null | wc -l' 2>/dev/null || echo "0")
        echo -e "  Home Manager: ${GREEN}available${NC} ($gen_count generations)"
    else
        echo -e "  Home Manager: ${YELLOW}not configured${NC}"
    fi

    # Show current generation
    echo ""
    log_step "Current Home Manager generation:"
    ssh "$NYX_HOST" '. ~/.nix-profile/etc/profile.d/nix.sh 2>/dev/null && home-manager generations 2>/dev/null | head -3' 2>/dev/null || echo "  (unable to query)"

    # Show Nix-managed packages
    echo ""
    log_step "Nix-managed packages:"
    local packages=("age" "sops" "node" "rclone" "ffmpeg" "pandoc" "gh" "jq" "git" "curl" "rsync")
    for pkg in "${packages[@]}"; do
        if ssh "$NYX_HOST" ". ~/.nix-profile/etc/profile.d/nix.sh 2>/dev/null && command -v $pkg &>/dev/null" 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} $pkg"
        else
            echo -e "  ${RED}[MISSING]${NC} $pkg"
        fi
    done
}

main() {
    case "${1:-}" in
        --check-apt)
            check_apt_packages
            ;;
        --status)
            show_nix_status
            ;;
        -h|--help|"")
            usage
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
