# SOPS + Age Secrets Encryption Setup

## Overview

Openclaw secrets are encrypted at rest using **age** (encryption) + **sops** (secrets management). Decryption happens automatically at boot via a system-level systemd service that writes secrets to a tmpfs mount (RAM only).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    STARTUP (System Service)                   │
│                                                              │
│  systemd starts home-fx-.openclaw-runtime.mount (tmpfs)     │
│                          │                                   │
│                          ▼                                   │
│  ┌─────────────────────────────────────────────┐            │
│  │  /usr/local/bin/openclaw-start.sh (as root) │            │
│  │  - mounts tmpfs at ~/.openclaw/runtime/     │            │
│  │  - sops decrypt openclaw.json.enc → tmpfs   │            │
│  │  - age decrypt telegram-bot-token.enc → tmpfs│            │
│  │  - age decrypt himalaya, market-apis, etc.  │            │
│  │  - creates symlinks from original paths     │            │
│  └─────────────────────────────────────────────┘            │
│       Uses /root/.config/sops/age/keys.txt (root-only)      │
│                          │                                   │
│                          ▼                                   │
│  Runtime decrypted files (fx-owned, 600 perms):             │
│  - ~/.openclaw/runtime/openclaw.json                        │
│  - ~/.openclaw/runtime/telegram-bot-token                   │
│  - ~/.openclaw/runtime/himalaya-config.toml                 │
│  - ~/.openclaw/runtime/market-apis.json                     │
│  - ~/.openclaw/runtime/perplexity.env                       │
│  - ~/.openclaw/runtime/readwise.json                        │
│                          │                                   │
│                          ▼                                   │
│  Symlinks: ~/.openclaw/openclaw.json → runtime/openclaw.json│
│            ~/.secrets/telegram-bot-token → runtime/...       │
│                          │                                   │
│                          ▼                                   │
│      exec su - fx ... openclaw gateway run (foreground)     │
└─────────────────────────────────────────────────────────────┘
```

## File Locations

| File | Purpose | Permissions |
|------|---------|-------------|
| `/root/.config/sops/age/keys.txt` | Age private key | root:root 600 |
| `~/.openclaw/openclaw.json.enc` | SOPS encrypted config | fx:fx 644 |
| `~/.secrets/telegram-bot-token.enc` | AGE encrypted token | fx:fx 644 |
| `~/.secrets/himalaya-config.toml.enc` | AGE encrypted email config | fx:fx 644 |
| `~/.secrets/market-apis.json.enc` | AGE encrypted market API keys | fx:fx 644 |
| `~/.secrets/perplexity.env.enc` | AGE encrypted Perplexity key | fx:fx 644 |
| `~/.secrets/readwise.json.enc` | AGE encrypted Readwise token | fx:fx 644 |
| `~/.secrets/rclone.conf.enc` | AGE encrypted rclone config | fx:fx 644 |
| `~/.openclaw/.sops.yaml` | SOPS config (which fields to encrypt) | fx:fx 644 |
| `/usr/local/bin/openclaw-start.sh` | Startup wrapper (decrypt + start) | root:root 755 |
| `/etc/systemd/system/openclaw.service` | Systemd service (system-level) | root:root 644 |
| `/etc/systemd/system/home-fx-.openclaw-runtime.mount` | tmpfs mount unit | root:root 644 |

## Runtime (tmpfs)

Decrypted secrets live only in RAM at `~/.openclaw/runtime/`:

```
~/.openclaw/runtime/       (tmpfs, 2MB, mode 0700)
├── openclaw.json          (decrypted main config)
├── telegram-bot-token     (decrypted token)
├── himalaya-config.toml   (decrypted email config)
├── market-apis.json       (decrypted API keys)
├── perplexity.env         (decrypted Perplexity key)
└── readwise.json          (decrypted Readwise token)
```

On reboot, the tmpfs is wiped. Secrets are re-decrypted by `openclaw-start.sh` at service startup.

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

### Edit encrypted config (decrypt, edit, re-encrypt)
```bash
sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops ~/.openclaw/openclaw.json.enc
```

### Restart openclaw
```bash
sudo systemctl restart openclaw
sudo systemctl status openclaw
```

## Systemd Service

`/etc/systemd/system/openclaw.service`:
```ini
[Unit]
Description=Openclaw Gateway
After=network.target home-fx-.openclaw-runtime.mount
Requires=home-fx-.openclaw-runtime.mount

[Service]
Type=simple
Environment="XDG_RUNTIME_DIR=/run/user/1000"
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
ExecStart=/usr/local/bin/openclaw-start.sh
Restart=always
RestartSec=5
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/fx/.openclaw /home/fx/.secrets /home/fx/clawd /home/fx/.config/rclone
PrivateTmp=true
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
```

## tmpfs Mount Unit

`/etc/systemd/system/home-fx-.openclaw-runtime.mount`:
```ini
[Unit]
Description=Openclaw Runtime Secrets (tmpfs)
Before=openclaw.service

[Mount]
What=tmpfs
Where=/home/fx/.openclaw/runtime
Type=tmpfs
Options=nodev,nosuid,noexec,size=2M,uid=1000,gid=1000,mode=0700

[Install]
WantedBy=multi-user.target
```

## Troubleshooting

### Openclaw won't start after reboot
1. Check tmpfs mount:
   ```bash
   mount | grep runtime
   ```
2. Check if decryption worked:
   ```bash
   ls -la ~/.openclaw/runtime/
   ```
3. Check service logs:
   ```bash
   sudo journalctl -u openclaw -n 50
   ```
4. Try manual decrypt:
   ```bash
   sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
     sops -d --output-type json ~/.openclaw/openclaw.json.enc
   ```

### Lost the age private key
Restore from 1Password secrets bundle or Dropbox:
```bash
rclone copy dropbox:nyx-backup/secrets/age/age-keys-backup.txt /tmp/
sudo mkdir -p /root/.config/sops/age
sudo mv /tmp/age-keys-backup.txt /root/.config/sops/age/keys.txt
sudo chmod 600 /root/.config/sops/age/keys.txt
```

### Need to add new secrets
1. Create and encrypt the file:
   ```bash
   # For JSON (structured): use SOPS
   sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt sops -e -i file.json
   mv file.json file.json.enc

   # For plain text: use AGE
   age -r $(sudo cat /root/.config/sops/age/keys.txt | grep "public key:" | cut -d: -f2 | tr -d ' ') \
     -o file.enc file && shred -u file
   ```
2. Add decryption block to `/usr/local/bin/openclaw-start.sh`
3. Restart: `sudo systemctl restart openclaw`

## Security Model

- **Age private key**: Only readable by root
- **Encrypted files**: Can be world-readable (useless without key)
- **Decrypted files**: Written to tmpfs at startup with 600 perms, owned by fx
- **tmpfs**: RAM-only filesystem, wiped on reboot, no disk forensics possible
- **Systemd hardening**: `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=true`
- **Threat model**: Protects against fx-user compromise; attacker would need root to get the key
