# SOPS + Age Secrets Encryption Setup

## Overview

Clawdbot secrets are encrypted at rest using **age** (encryption) + **sops** (secrets management). Decryption happens automatically at gateway startup.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         STARTUP                              │
│                                                              │
│  /root/.config/sops/age/keys.txt (private key, root-only)   │
│                          │                                   │
│                          ▼                                   │
│  ┌─────────────────────────────────────────────┐            │
│  │  /usr/local/bin/clawdbot-start.sh           │            │
│  │  - sops decrypt clawdbot.json.enc           │            │
│  │  - age decrypt telegram-bot-token.enc       │            │
│  └─────────────────────────────────────────────┘            │
│                          │                                   │
│                          ▼                                   │
│  Runtime decrypted files (fx-owned, 600 perms):             │
│  - ~/.clawdbot/clawdbot.json                                │
│  - ~/.secrets/telegram-bot-token                            │
│                          │                                   │
│                          ▼                                   │
│              clawdbot gateway start                          │
└─────────────────────────────────────────────────────────────┘
```

## File Locations

| File | Purpose | Permissions |
|------|---------|-------------|
| `/root/.config/sops/age/keys.txt` | Age private key | root:root 600 |
| `~/.clawdbot/clawdbot.json.enc` | Encrypted config | fx:fx 644 |
| `~/.secrets/telegram-bot-token.enc` | Encrypted telegram token | fx:fx 644 |
| `~/.clawdbot/.sops.yaml` | SOPS config (which fields to encrypt) | fx:fx 644 |
| `/usr/local/bin/clawdbot-start.sh` | Startup wrapper script | root:root 755 |
| `/etc/systemd/system/clawdbot.service` | Systemd service | root:root 644 |

## Backup Location

Backups stored in cloud storage:
- `secrets/age/` — private key backup
- `secrets/clawdbot/` — encrypted config and tokens

## Key Commands

### View age public key
```bash
sudo cat /root/.config/sops/age/keys.txt | grep "public key:"
```

### Decrypt config manually
```bash
sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops -d --output-type json ~/.clawdbot/clawdbot.json.enc
```

### Decrypt telegram token manually
```bash
sudo age -d -i /root/.config/sops/age/keys.txt ~/.secrets/telegram-bot-token.enc
```

### Edit encrypted config (decrypt → edit → re-encrypt)
```bash
sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops ~/.clawdbot/clawdbot.json.enc
```

### Re-encrypt after manual changes
```bash
# If you edited the decrypted .json directly:
# Get your public key from: /root/.config/sops/age/keys.txt (line starting with "public key:")
AGE_PUB="<AGE_PUBLIC_KEY>"
sops -e --age $AGE_PUB ~/.clawdbot/clawdbot.json > ~/.clawdbot/clawdbot.json.enc
```

### Restart clawdbot
```bash
sudo systemctl restart clawdbot
sudo systemctl status clawdbot
```

## Startup Script

`/usr/local/bin/clawdbot-start.sh`:
```bash
#!/bin/bash
set -e

SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE

CONFIG_DIR=/home/fx/.clawdbot
SECRETS_DIR=/home/fx/.secrets

# Decrypt clawdbot.json
if [ -f "$CONFIG_DIR/clawdbot.json.enc" ]; then
  sops -d --output-type json "$CONFIG_DIR/clawdbot.json.enc" > "$CONFIG_DIR/clawdbot.json"
  chown fx:fx "$CONFIG_DIR/clawdbot.json"
  chmod 600 "$CONFIG_DIR/clawdbot.json"
fi

# Decrypt telegram token
if [ -f "$SECRETS_DIR/telegram-bot-token.enc" ]; then
  age -d -i /root/.config/sops/age/keys.txt \
    "$SECRETS_DIR/telegram-bot-token.enc" > "$SECRETS_DIR/telegram-bot-token"
  chown fx:fx "$SECRETS_DIR/telegram-bot-token"
  chmod 600 "$SECRETS_DIR/telegram-bot-token"
fi

# Run clawdbot as fx user
exec sudo -u fx /home/fx/.local/share/npm-global/bin/clawdbot gateway start
```

## Systemd Service

`/etc/systemd/system/clawdbot.service`:
```ini
[Unit]
Description=Clawdbot Gateway
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/clawdbot-start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Troubleshooting

### Clawdbot won't start after reboot
1. Check if decryption worked:
   ```bash
   ls -la ~/.clawdbot/clawdbot.json
   ls -la ~/.secrets/telegram-bot-token
   ```
2. Check systemd logs:
   ```bash
   sudo journalctl -u clawdbot -n 50
   ```
3. Try manual decrypt:
   ```bash
   sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
     sops -d --output-type json ~/.clawdbot/clawdbot.json.enc
   ```

### Lost the age private key
Restore from cloud backup and place at `/root/.config/sops/age/keys.txt` with 600 permissions.

## Recovery

### Full Recovery from Dropbox Backup

```bash
# 1. Restore age private key
rclone copy dropbox:nyx-backup/secrets/age/ /tmp/age-restore/
sudo mkdir -p /root/.config/sops/age
sudo cp /tmp/age-restore/age-keys-backup.txt /root/.config/sops/age/keys.txt
sudo chmod 600 /root/.config/sops/age/keys.txt
sudo chown root:root /root/.config/sops/age/keys.txt
rm -rf /tmp/age-restore

# 2. Restore encrypted configs
rclone copy dropbox:nyx-backup/secrets/clawdbot/ ~/.clawdbot/
chmod 644 ~/.clawdbot/clawdbot.json.enc

# 3. Restore telegram token
mkdir -p ~/.secrets
rclone copy dropbox:nyx-backup/secrets/telegram/ ~/.secrets/
chmod 644 ~/.secrets/telegram-bot-token.enc

# 4. Restart service (will decrypt on startup)
sudo systemctl restart clawdbot
```

### Verify Backup Integrity

```bash
# List backup contents
rclone ls dropbox:nyx-backup/secrets/

# Test decryption without overwriting
sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops -d ~/.clawdbot/clawdbot.json.enc | head -5
```

### Need to add new secrets
1. Edit the encrypted file directly:
   ```bash
   sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
     sops ~/.clawdbot/clawdbot.json.enc
   ```
   This decrypts, opens in $EDITOR, and re-encrypts on save.

## Security Model

- **Age private key**: Only readable by root
- **Encrypted files**: Can be world-readable (useless without key)
- **Decrypted files**: Created at startup with 600 perms, owned by fx
- **Threat model**: Protects against fx-user compromise; attacker would need root to get the key

## Installed Tools

- `age` v1.1.1 — `/usr/bin/age`
- `sops` v3.8.1 — `/usr/local/bin/sops`
