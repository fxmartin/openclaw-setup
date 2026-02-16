#!/bin/bash
# ABOUTME: Installs Beszel hub+agent and Uptime Kuma on Nyx for centralised monitoring
# ABOUTME: Downloads binaries, configures systemd user services, and enables them

set -euo pipefail

# ============================================
# Environment Setup (for cron/remote exec)
# ============================================

if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export PATH="$HOME/.nix-profile/bin:$HOME/.local/share/npm-global/bin:$HOME/.local/bin:$PATH"

# ============================================
# Configuration
# ============================================

BESZEL_HUB_PORT="${BESZEL_HUB_PORT:-8090}"
BESZEL_AGENT_PORT="${BESZEL_AGENT_PORT:-45876}"
UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-3001}"

BESZEL_DATA_DIR="$HOME/.beszel"
UPTIME_KUMA_DIR="$HOME/.uptime-kuma"
BIN_DIR="$HOME/.local/bin"
SERVICE_DIR="$HOME/.config/systemd/user"

# Beszel release URL pattern (auto-detect arch)
BESZEL_BASE_URL="https://github.com/henrygd/beszel/releases/latest/download"

# ============================================
# Logging
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "\n${BLUE}═══${NC} $1 ${BLUE}═══${NC}"; }

# ============================================
# Helpers
# ============================================

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       echo "$arch" ;;
    esac
}

detect_os() {
    uname -s
}

# ============================================
# Phase 1: Beszel Hub
# ============================================

install_beszel_hub() {
    log_step "Installing Beszel Hub"

    local os arch tarball_url
    os=$(detect_os)
    arch=$(detect_arch)
    tarball_url="${BESZEL_BASE_URL}/beszel_${os}_${arch}.tar.gz"

    # Create directories
    mkdir -p "$BIN_DIR" "$BESZEL_DATA_DIR" "$SERVICE_DIR"

    # Download and extract hub binary (idempotent)
    if [[ -f "$BIN_DIR/beszel" ]]; then
        log_info "Beszel hub binary already exists, updating..."
    fi

    log_info "Downloading beszel hub for ${os}/${arch}..."
    if ! curl -sL "$tarball_url" | tar -xz -C "$BIN_DIR" beszel 2>/dev/null; then
        log_error "Failed to download beszel hub from: $tarball_url"
        return 1
    fi
    chmod 755 "$BIN_DIR/beszel"

    log_ok "Beszel hub binary installed: $BIN_DIR/beszel"
}

install_beszel_hub_service() {
    log_info "Installing beszel-hub systemd user service"

    # Skip if service file was already placed (e.g. by nyx-provision.sh)
    if [[ -f "$SERVICE_DIR/beszel-hub.service" ]]; then
        log_info "Service file already exists at $SERVICE_DIR/beszel-hub.service, keeping it"
    else
        # Try to copy from repo config, else use embedded fallback
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local repo_dir
        repo_dir="$(dirname "$script_dir")"
        local service_src="${repo_dir}/config/beszel-hub.service"

        if [[ -f "$service_src" ]]; then
            cp "$service_src" "$SERVICE_DIR/beszel-hub.service"
        else
            log_warn "Service file not found at $service_src, using embedded config"
            cat > "$SERVICE_DIR/beszel-hub.service" <<EOF
[Unit]
Description=Beszel Hub - System Resource Monitoring Dashboard
After=network.target

[Service]
Type=simple
Environment=PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$BIN_DIR/beszel serve --http 0.0.0.0:$BESZEL_HUB_PORT
WorkingDirectory=$BESZEL_DATA_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
        fi
    fi

    systemctl --user daemon-reload
    systemctl --user enable beszel-hub
    systemctl --user start beszel-hub

    log_ok "Beszel Hub running on port $BESZEL_HUB_PORT"
}

# ============================================
# Phase 2: Beszel Agent (self-monitoring)
# ============================================

install_beszel_agent() {
    log_step "Installing Beszel Agent"

    local os arch tarball_url
    os=$(detect_os)
    arch=$(detect_arch)
    tarball_url="${BESZEL_BASE_URL}/beszel-agent_${os}_${arch}.tar.gz"

    mkdir -p "$BIN_DIR"

    if [[ -f "$BIN_DIR/beszel-agent" ]]; then
        log_info "Beszel agent binary already exists, updating..."
    fi

    log_info "Downloading beszel agent for ${os}/${arch}..."
    if ! curl -sL "$tarball_url" | tar -xz -C "$BIN_DIR" beszel-agent 2>/dev/null; then
        log_error "Failed to download beszel agent from: $tarball_url"
        return 1
    fi
    chmod 755 "$BIN_DIR/beszel-agent"

    log_ok "Beszel agent binary installed: $BIN_DIR/beszel-agent"
}

install_beszel_agent_service() {
    log_info "Installing beszel-agent systemd user service"

    local env_file="$HOME/.config/beszel-agent.env"

    # Check if agent env is configured
    if [[ ! -f "$env_file" ]]; then
        log_warn "Agent environment file not found: $env_file"
        echo ""
        echo "After adding this system in Beszel Hub (http://localhost:$BESZEL_HUB_PORT),"
        echo "create the env file with the key from the Hub UI:"
        echo ""
        echo "  cat > $env_file << 'ENVEOF'"
        echo "  KEY=<ssh-public-key-from-hub>"
        echo "  PORT=$BESZEL_AGENT_PORT"
        echo "  ENVEOF"
        echo ""
        echo "Then run: systemctl --user start beszel-agent"
        echo ""

        # Create placeholder so service file is valid
        cat > "$env_file" <<EOF
# Beszel agent configuration
# Get the KEY value from Beszel Hub after adding this system
KEY=
PORT=$BESZEL_AGENT_PORT
EOF
    fi

    # Skip if service file was already placed (e.g. by nyx-provision.sh)
    if [[ -f "$SERVICE_DIR/beszel-agent.service" ]]; then
        log_info "Service file already exists at $SERVICE_DIR/beszel-agent.service, keeping it"
    else
        # Try to copy from repo config, else use embedded fallback
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local repo_dir
        repo_dir="$(dirname "$script_dir")"
        local service_src="${repo_dir}/config/beszel-agent.service"

        if [[ -f "$service_src" ]]; then
            cp "$service_src" "$SERVICE_DIR/beszel-agent.service"
        else
            log_warn "Service file not found at $service_src, using embedded config"
            cat > "$SERVICE_DIR/beszel-agent.service" <<EOF
[Unit]
Description=Beszel Agent - System Resource Metrics Collector
After=network.target

[Service]
Type=simple
Environment=PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=$env_file
ExecStart=$BIN_DIR/beszel-agent
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
        fi
    fi

    systemctl --user daemon-reload
    systemctl --user enable beszel-agent

    # Only start if KEY is configured
    if grep -q '^KEY=.\+' "$env_file" 2>/dev/null; then
        systemctl --user start beszel-agent
        log_ok "Beszel Agent running on port $BESZEL_AGENT_PORT"
    else
        log_warn "Beszel Agent enabled but not started (KEY not configured)"
    fi
}

# ============================================
# Phase 3: Uptime Kuma
# ============================================

install_uptime_kuma() {
    log_step "Installing Uptime Kuma"

    # Requires Node.js (provided by Nix)
    if ! command -v node &>/dev/null; then
        log_error "Node.js not found. Install via Nix first."
        return 1
    fi

    if ! command -v npm &>/dev/null; then
        log_error "npm not found. Install via Nix first."
        return 1
    fi

    mkdir -p "$UPTIME_KUMA_DIR"

    if [[ -f "$UPTIME_KUMA_DIR/server/server.js" ]]; then
        log_info "Uptime Kuma already installed, updating..."
        (
            cd "$UPTIME_KUMA_DIR"
            git fetch --tags
            local latest_tag
            latest_tag=$(git describe --tags --abbrev=0 origin/master 2>/dev/null || git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "")
            if [[ -n "$latest_tag" ]]; then
                local current_tag
                current_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
                if [[ "$current_tag" != "$latest_tag" ]]; then
                    log_info "Updating from $current_tag to $latest_tag"
                    git checkout "$latest_tag"
                    npm run setup
                else
                    log_ok "Uptime Kuma already at latest version: $current_tag"
                fi
            fi
        )
    else
        log_info "Cloning Uptime Kuma repository..."
        git clone --depth 1 https://github.com/louislam/uptime-kuma.git "$UPTIME_KUMA_DIR"
        (
            cd "$UPTIME_KUMA_DIR"
            log_info "Running npm setup..."
            npm run setup
        )
    fi

    log_ok "Uptime Kuma installed at $UPTIME_KUMA_DIR"
}

install_uptime_kuma_service() {
    log_info "Installing uptime-kuma systemd user service"

    # Skip if service file was already placed (e.g. by nyx-provision.sh)
    if [[ -f "$SERVICE_DIR/uptime-kuma.service" ]]; then
        log_info "Service file already exists at $SERVICE_DIR/uptime-kuma.service, keeping it"
    else
        # Try to copy from repo config, else use embedded fallback
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local repo_dir
        repo_dir="$(dirname "$script_dir")"
        local service_src="${repo_dir}/config/uptime-kuma.service"

        if [[ -f "$service_src" ]]; then
            cp "$service_src" "$SERVICE_DIR/uptime-kuma.service"
        else
            log_warn "Service file not found at $service_src, using embedded config"
            cat > "$SERVICE_DIR/uptime-kuma.service" <<EOF
[Unit]
Description=Uptime Kuma - Service Availability Monitoring
After=network.target

[Service]
Type=simple
Environment=PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:$HOME/.local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$(command -v node) $UPTIME_KUMA_DIR/server/server.js --host 0.0.0.0 --port $UPTIME_KUMA_PORT
WorkingDirectory=$UPTIME_KUMA_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
        fi
    fi

    systemctl --user daemon-reload
    systemctl --user enable uptime-kuma
    systemctl --user start uptime-kuma

    log_ok "Uptime Kuma running on port $UPTIME_KUMA_PORT"
}

# ============================================
# Main
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Beszel (hub + agent) and Uptime Kuma monitoring stack.

OPTIONS:
    --hub-only          Install only Beszel Hub
    --agent-only        Install only Beszel Agent
    --uptime-kuma-only  Install only Uptime Kuma
    --skip-hub          Skip Beszel Hub installation
    --skip-agent        Skip Beszel Agent installation
    --skip-uptime-kuma  Skip Uptime Kuma installation
    -h, --help          Show this help

EXAMPLES:
    $(basename "$0")                    # Install everything
    $(basename "$0") --hub-only         # Hub only (first run)
    $(basename "$0") --agent-only       # Agent only (after configuring key)
EOF
}

INSTALL_HUB=1
INSTALL_AGENT=1
INSTALL_UPTIME_KUMA=1

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hub-only)
                INSTALL_AGENT=0
                INSTALL_UPTIME_KUMA=0
                shift
                ;;
            --agent-only)
                INSTALL_HUB=0
                INSTALL_UPTIME_KUMA=0
                shift
                ;;
            --uptime-kuma-only)
                INSTALL_HUB=0
                INSTALL_AGENT=0
                shift
                ;;
            --skip-hub)
                INSTALL_HUB=0
                shift
                ;;
            --skip-agent)
                INSTALL_AGENT=0
                shift
                ;;
            --skip-uptime-kuma)
                INSTALL_UPTIME_KUMA=0
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

main() {
    parse_args "$@"

    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Nyx Monitoring Stack Installer"
    echo "═══════════════════════════════════════════"
    echo ""

    # Ensure systemd user directory exists
    mkdir -p "$SERVICE_DIR"

    if [[ $INSTALL_HUB -eq 1 ]]; then
        install_beszel_hub
        install_beszel_hub_service
    fi

    if [[ $INSTALL_AGENT -eq 1 ]]; then
        install_beszel_agent
        install_beszel_agent_service
    fi

    if [[ $INSTALL_UPTIME_KUMA -eq 1 ]]; then
        install_uptime_kuma
        install_uptime_kuma_service
    fi

    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Installation Summary"
    echo "═══════════════════════════════════════════"
    echo ""

    if [[ $INSTALL_HUB -eq 1 ]]; then
        echo "  Beszel Hub:     http://0.0.0.0:$BESZEL_HUB_PORT"
        echo "  Data directory: $BESZEL_DATA_DIR"
    fi
    if [[ $INSTALL_AGENT -eq 1 ]]; then
        echo "  Beszel Agent:   port $BESZEL_AGENT_PORT"
        echo "  Agent config:   $HOME/.config/beszel-agent.env"
    fi
    if [[ $INSTALL_UPTIME_KUMA -eq 1 ]]; then
        echo "  Uptime Kuma:    http://0.0.0.0:$UPTIME_KUMA_PORT"
        echo "  Data directory: $UPTIME_KUMA_DIR"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Access Beszel Hub and create admin account"
    echo "  2. Add this system in Beszel Hub to get the agent KEY"
    echo "  3. Update $HOME/.config/beszel-agent.env with the KEY"
    echo "  4. Run: systemctl --user restart beszel-agent"
    echo "  5. Access Uptime Kuma and configure monitors"
    echo ""
}

main "$@"
