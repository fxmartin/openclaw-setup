#!/bin/bash
# openclaw-start.sh - Start script for openclaw gateway
# Install to: /usr/local/bin/openclaw-start.sh (root:root 755)
#
# This script:
#   1. Ensures tmpfs is mounted for runtime secrets
#   2. Decrypts secrets to tmpfs (RAM only)
#   3. Creates symlinks for compatibility
#   4. Starts openclaw gateway as user fx
#
# Called by: /etc/systemd/system/openclaw.service

set -e

USER="fx"
USER_HOME="/home/$USER"
OPENCLAW_DIR="$USER_HOME/.openclaw"
SECRETS_DIR="$USER_HOME/.secrets"
RUNTIME_DIR="$OPENCLAW_DIR/runtime"
AGE_KEY="/root/.config/sops/age/keys.txt"
OPENCLAW_BIN="$USER_HOME/.local/share/npm-global/bin/openclaw"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    exit 1
}

# Verify prerequisites
[[ -f "$AGE_KEY" ]] || error "AGE key not found: $AGE_KEY"
[[ -d "$OPENCLAW_DIR" ]] || error "Openclaw directory not found: $OPENCLAW_DIR"

# Ensure runtime directory exists
mkdir -p "$RUNTIME_DIR"

# Check if tmpfs is mounted, mount if not
if ! mountpoint -q "$RUNTIME_DIR"; then
    log "Mounting tmpfs at $RUNTIME_DIR"
    mount -t tmpfs -o nodev,nosuid,noexec,size=2M,uid=1000,gid=1000,mode=0700 tmpfs "$RUNTIME_DIR"
fi

# Decrypt openclaw.json.enc if exists
if [[ -f "$OPENCLAW_DIR/openclaw.json.enc" ]]; then
    log "Decrypting openclaw.json.enc to tmpfs"
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d --output-type json \
        "$OPENCLAW_DIR/openclaw.json.enc" > "$RUNTIME_DIR/openclaw.json"
    chown "$USER:$USER" "$RUNTIME_DIR/openclaw.json"
    chmod 600 "$RUNTIME_DIR/openclaw.json"

    # Create symlink if not exists
    if [[ ! -L "$OPENCLAW_DIR/openclaw.json" ]]; then
        rm -f "$OPENCLAW_DIR/openclaw.json"
        ln -sf "runtime/openclaw.json" "$OPENCLAW_DIR/openclaw.json"
    fi
fi

# Decrypt telegram-bot-token.enc if exists
if [[ -f "$SECRETS_DIR/telegram-bot-token.enc" ]]; then
    log "Decrypting telegram-bot-token.enc to tmpfs"
    age -d -i "$AGE_KEY" "$SECRETS_DIR/telegram-bot-token.enc" > "$RUNTIME_DIR/telegram-bot-token"
    chown "$USER:$USER" "$RUNTIME_DIR/telegram-bot-token"
    chmod 600 "$RUNTIME_DIR/telegram-bot-token"

    # Create symlink if not exists
    if [[ ! -L "$SECRETS_DIR/telegram-bot-token" ]]; then
        rm -f "$SECRETS_DIR/telegram-bot-token"
        ln -sf "$RUNTIME_DIR/telegram-bot-token" "$SECRETS_DIR/telegram-bot-token"
    fi
fi

# Decrypt himalaya config if exists
if [[ -f "$SECRETS_DIR/himalaya-config.toml.enc" ]]; then
    log "Decrypting himalaya-config.toml.enc to tmpfs"
    age -d -i "$AGE_KEY" "$SECRETS_DIR/himalaya-config.toml.enc" > "$RUNTIME_DIR/himalaya-config.toml"
    chown "$USER:$USER" "$RUNTIME_DIR/himalaya-config.toml"
    chmod 600 "$RUNTIME_DIR/himalaya-config.toml"

    # Create symlink for himalaya to find the config
    HIMALAYA_DIR="$USER_HOME/clawd/.himalaya"
    mkdir -p "$HIMALAYA_DIR"
    if [[ ! -L "$HIMALAYA_DIR/config.toml" ]]; then
        rm -f "$HIMALAYA_DIR/config.toml"
        ln -sf "$RUNTIME_DIR/himalaya-config.toml" "$HIMALAYA_DIR/config.toml"
    fi
    chown -R "$USER:$USER" "$HIMALAYA_DIR"
fi

# Decrypt market API keys if exists
if [[ -f "$SECRETS_DIR/market-apis.json.enc" ]]; then
    log "Decrypting market-apis.json.enc to tmpfs"
    age -d -i "$AGE_KEY" "$SECRETS_DIR/market-apis.json.enc" > "$RUNTIME_DIR/market-apis.json"
    chown "$USER:$USER" "$RUNTIME_DIR/market-apis.json"
    chmod 600 "$RUNTIME_DIR/market-apis.json"

    # Create symlink
    if [[ ! -L "$SECRETS_DIR/market-apis.json" ]]; then
        rm -f "$SECRETS_DIR/market-apis.json"
        ln -sf "$RUNTIME_DIR/market-apis.json" "$SECRETS_DIR/market-apis.json"
    fi
fi

# Decrypt Perplexity API key if exists
if [[ -f "$SECRETS_DIR/perplexity.env.enc" ]]; then
    log "Decrypting perplexity.env.enc to tmpfs"
    age -d -i "$AGE_KEY" "$SECRETS_DIR/perplexity.env.enc" > "$RUNTIME_DIR/perplexity.env"
    chown "$USER:$USER" "$RUNTIME_DIR/perplexity.env"
    chmod 600 "$RUNTIME_DIR/perplexity.env"

    # Create symlink
    if [[ ! -L "$SECRETS_DIR/perplexity.env" ]]; then
        rm -f "$SECRETS_DIR/perplexity.env"
        ln -sf "$RUNTIME_DIR/perplexity.env" "$SECRETS_DIR/perplexity.env"
    fi
fi

# Decrypt Readwise API token if exists
if [[ -f "$SECRETS_DIR/readwise.json.enc" ]]; then
    log "Decrypting readwise.json.enc to tmpfs"
    age -d -i "$AGE_KEY" "$SECRETS_DIR/readwise.json.enc" > "$RUNTIME_DIR/readwise.json"
    chown "$USER:$USER" "$RUNTIME_DIR/readwise.json"
    chmod 600 "$RUNTIME_DIR/readwise.json"

    # Create symlink
    if [[ ! -L "$SECRETS_DIR/readwise.json" ]]; then
        rm -f "$SECRETS_DIR/readwise.json"
        ln -sf "$RUNTIME_DIR/readwise.json" "$SECRETS_DIR/readwise.json"
    fi
fi

# Decrypt rclone config if exists (needed for Dropbox backups)
if [[ -f "$SECRETS_DIR/rclone.conf.enc" ]]; then
    log "Decrypting rclone.conf.enc"
    RCLONE_DIR="$USER_HOME/.config/rclone"
    mkdir -p "$RCLONE_DIR"
    age -d -i "$AGE_KEY" "$SECRETS_DIR/rclone.conf.enc" > "$RCLONE_DIR/rclone.conf"
    chown -R "$USER:$USER" "$RCLONE_DIR"
    chmod 600 "$RCLONE_DIR/rclone.conf"
fi

log "Starting openclaw gateway as user $USER"

# Run as user fx with proper environment
# Include Nix profile bin for node and other Nix-managed tools
# Use 'gateway run' (foreground) instead of 'gateway start' (systemd service trigger)
# OPENCLAW_GATEWAY_TOKEN is required for gateway auth (value can be any string for local use)
exec su - "$USER" -c "
    export PATH=$USER_HOME/.nix-profile/bin:$USER_HOME/.local/share/npm-global/bin:$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
    export XDG_RUNTIME_DIR=/run/user/1000
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
    export OPENCLAW_GATEWAY_TOKEN=local-gateway-token
    cd $USER_HOME/clawd
    $OPENCLAW_BIN gateway run
"
