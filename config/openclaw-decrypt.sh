#!/bin/bash
# openclaw-decrypt.sh - Decrypt wrapper for user service
# Install to: /usr/local/bin/openclaw-decrypt.sh (root:root 755)
#
# Called by: ExecStartPre in user systemd service
# This is used when running openclaw as a user service instead of system service
#
# The user fx can run this via sudo without password (see sudoers.d/openclaw-decrypt)

set -e

CONFIG_DIR=/home/fx/.openclaw
SECRETS_DIR=/home/fx/.secrets

# Decrypt openclaw config if encrypted version exists
if [[ -f "$CONFIG_DIR/openclaw.json.enc" ]]; then
    sudo /usr/local/bin/sops-decrypt-config
fi

# Decrypt telegram token if encrypted version exists
if [[ -f "$SECRETS_DIR/telegram-bot-token.enc" ]]; then
    sudo /usr/local/bin/age-decrypt-token
fi
