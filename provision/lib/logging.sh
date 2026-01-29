#!/usr/bin/env bash
# logging.sh - Colored logging utilities for provisioning scripts
# Source this file: source "$(dirname "$0")/lib/logging.sh"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_fatal() {
    echo -e "${RED}${BOLD}[FATAL]${NC} $*" >&2
    exit 1
}

log_step() {
    echo -e "\n${CYAN}${BOLD}==> $*${NC}"
}

log_substep() {
    echo -e "  ${MAGENTA}->$NC $*"
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $*" >&2
    fi
}

# Progress indicator
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "      \b\b\b\b\b\b"
}

# Confirmation prompt
confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -rp "$prompt" response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy]$ ]]
}

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root (use sudo)"
    fi
}

# Check if a command exists
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log_fatal "Required command not found: $cmd"
    fi
}

# Check multiple commands
require_commands() {
    for cmd in "$@"; do
        require_command "$cmd"
    done
}

# Print a separator line
separator() {
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# Print banner
banner() {
    local text="$1"
    echo ""
    separator
    echo -e "${BOLD}${CYAN}  $text${NC}"
    separator
    echo ""
}

# Safe execution with error handling
run_cmd() {
    local description="$1"
    shift

    log_substep "$description"
    if ! "$@" 2>&1; then
        log_error "Failed: $description"
        return 1
    fi
    return 0
}

# Check file exists
require_file() {
    local file="$1"
    local description="${2:-Required file}"

    if [[ ! -f "$file" ]]; then
        log_fatal "$description not found: $file"
    fi
}

# Check directory exists
require_dir() {
    local dir="$1"
    local description="${2:-Required directory}"

    if [[ ! -d "$dir" ]]; then
        log_fatal "$description not found: $dir"
    fi
}
