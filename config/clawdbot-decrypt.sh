#!/bin/bash
# clawdbot-decrypt.sh - Decrypt wrapper for user service
# Install to: /usr/local/bin/clawdbot-decrypt.sh (root:root 755)
#
# Called by: ExecStartPre in user systemd service
# This is used when running clawdbot as a user service instead of system service
#
# The user fx can run this via sudo without password (see sudoers.d/clawdbot-decrypt)

set -e

CONFIG_DIR=/home/fx/.clawdbot
SECRETS_DIR=/home/fx/.secrets

# Decrypt clawdbot config if encrypted version exists
if [[ -f "$CONFIG_DIR/clawdbot.json.enc" ]]; then
    sudo /usr/local/bin/sops-decrypt-config
fi

# Decrypt telegram token if encrypted version exists
if [[ -f "$SECRETS_DIR/telegram-bot-token.enc" ]]; then
    sudo /usr/local/bin/age-decrypt-token
fi
