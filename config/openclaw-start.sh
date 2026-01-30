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

log "Starting openclaw gateway as user $USER"

# Run as user fx with proper environment
exec su - "$USER" -c "
    export PATH=$USER_HOME/.local/share/npm-global/bin:$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
    export XDG_RUNTIME_DIR=/run/user/1000
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
    cd $USER_HOME/clawd
    $OPENCLAW_BIN gateway start
"
