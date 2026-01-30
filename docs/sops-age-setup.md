# SOPS + Age Secrets Encryption Setup

## Overview

Openclaw secrets are encrypted at rest using **age** (encryption) + **sops** (secrets management). Decryption happens automatically at gateway startup via a user systemd service.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    STARTUP (User Service)                    │
│                                                              │
│  loginctl enable-linger fx (user session persists)          │
│                          │                                   │
│                          ▼                                   │
│  ┌─────────────────────────────────────────────┐            │
│  │  ExecStartPre: openclaw-decrypt.sh          │            │
│  │    └─ sudo sops-decrypt-config              │            │
│  │    └─ sudo age-decrypt-token                │            │
│  └─────────────────────────────────────────────┘            │
│                          │                                   │
│        /root/.config/sops/age/keys.txt (root-only)          │
│                          │                                   │
│                          ▼                                   │
│  Runtime decrypted files (fx-owned, 600 perms):             │
│  - ~/.openclaw/openclaw.json                                │
│  - ~/.secrets/telegram-bot-token                            │
│                          │                                   │
│                          ▼                                   │
│              openclaw gateway start                          │
│                          │                                   │
│                          ▼                                   │
│        openclaw-gateway.service (user-managed, D-Bus ✓)     │
└─────────────────────────────────────────────────────────────┘
```

## File Locations

| File | Purpose | Permissions |
|------|---------|-------------|
| `/root/.config/sops/age/keys.txt` | Age private key | root:root 600 |
| `~/.openclaw/openclaw.json.enc` | Encrypted config | fx:fx 644 |
| `~/.secrets/telegram-bot-token.enc` | Encrypted telegram token | fx:fx 644 |
| `~/.openclaw/.sops.yaml` | SOPS config (which fields to encrypt) | fx:fx 644 |
| `/usr/local/bin/openclaw-decrypt.sh` | Decrypt wrapper (calls sudo) | root:root 755 |
| `/usr/local/bin/sops-decrypt-config` | SOPS decrypt helper | root:root 755 |
| `/usr/local/bin/age-decrypt-token` | Age decrypt helper | root:root 755 |
| `/etc/sudoers.d/openclaw-decrypt` | NOPASSWD rules for decrypt | root:root 440 |
| `~/.config/systemd/user/openclaw.service` | User systemd service | fx:fx 644 |

## Backup Location

Backups stored in Dropbox (`nyx-backup/secrets/`):
- `age/age-keys-backup.txt` — private key backup
- `openclaw/openclaw.json.enc` — encrypted config
- `openclaw/telegram-bot-token.enc` — encrypted token
- `gh/hosts.yml.enc` — encrypted GitHub token

## Key Commands

### View age public key
```bash
sudo cat /root/.config/sops/age/keys.txt | grep "public key:"
```

### Decrypt config manually
```bash
sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops -d --output-type json ~/.openclaw/openclaw.json.enc
```

### Decrypt telegram token manually
```bash
sudo age -d -i /root/.config/sops/age/keys.txt ~/.secrets/telegram-bot-token.enc
```

### Edit encrypted config (decrypt → edit → re-encrypt)
```bash
sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops ~/.openclaw/openclaw.json.enc
```

### Restart openclaw
```bash
systemctl --user restart openclaw.service
systemctl --user status openclaw-gateway.service
```

## User Service Setup

### Enable lingering
```bash
sudo loginctl enable-linger fx
```

### User service file
`~/.config/systemd/user/openclaw.service`:
```ini
[Unit]
Description=Openclaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/openclaw-decrypt.sh
ExecStart=/home/fx/.local/share/npm-global/bin/openclaw gateway start
Restart=always
RestartSec=5
Environment=PATH=/home/fx/.local/share/npm-global/bin:/home/fx/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
```

### Decrypt wrapper
`/usr/local/bin/openclaw-decrypt.sh`:
```bash
#!/bin/bash
set -e

CONFIG_DIR=/home/fx/.openclaw
SECRETS_DIR=/home/fx/.secrets

if [ -f "$CONFIG_DIR/openclaw.json.enc" ]; then
  sudo /usr/local/bin/sops-decrypt-config
fi

if [ -f "$SECRETS_DIR/telegram-bot-token.enc" ]; then
  sudo /usr/local/bin/age-decrypt-token
fi
```

### Sudoers config
`/etc/sudoers.d/openclaw-decrypt`:
```
fx ALL=(root) NOPASSWD: /usr/local/bin/sops-decrypt-config
fx ALL=(root) NOPASSWD: /usr/local/bin/age-decrypt-token
```

## Troubleshooting

### Openclaw won't start after reboot
1. Check if user session is running:
   ```bash
   loginctl user-status fx
   ```
2. Check if decryption worked:
   ```bash
   ls -la ~/.openclaw/openclaw.json
   ls -la ~/.secrets/telegram-bot-token
   ```
3. Check user service logs:
   ```bash
   journalctl --user -u openclaw -n 50
   journalctl --user -u openclaw-gateway -n 50
   ```
4. Try manual decrypt:
   ```bash
   /usr/local/bin/openclaw-decrypt.sh
   ```

### Lost the age private key
Restore from Dropbox:
```bash
rclone copy dropbox:nyx-backup/secrets/age/age-keys-backup.txt /tmp/
sudo mkdir -p /root/.config/sops/age
sudo mv /tmp/age-keys-backup.txt /root/.config/sops/age/keys.txt
sudo chmod 600 /root/.config/sops/age/keys.txt
```

### Need to add new secrets
Edit the encrypted file directly:
```bash
sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops ~/.openclaw/openclaw.json.enc
```
This decrypts, opens in $EDITOR, and re-encrypts on save.

## Security Model

- **Age private key**: Only readable by root
- **Encrypted files**: Can be world-readable (useless without key)
- **Decrypted files**: Created at startup with 600 perms, owned by fx
- **Sudo rules**: Narrowly scoped to specific decrypt scripts only
- **User service**: Proper D-Bus session, no privilege escalation in main process
- **Threat model**: Protects against fx-user compromise; attacker would need root to get the key

## Installed Tools

- `age` v1.1.1 — `/usr/bin/age`
- `sops` v3.8.1 — `/usr/local/bin/sops`
