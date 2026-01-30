# Nyx Disaster Recovery Setup

Complete documentation for the Clawdbot/Nyx server disaster recovery architecture.

## Overview

**Server:** nyx (Hetzner Cloud)
**IP:** 100.64.138.99 (Tailscale)
**OS:** Ubuntu 24.04 LTS
**User:** fx

The DR strategy follows a 3-2-1 approach:
- **3 copies:** Live + Dropbox + NAS
- **2 different media:** Cloud (Dropbox) + Local (NAS)
- **1 offsite:** Dropbox is offsite; NAS is on-premises (Luxembourg)

---

## Secrets Management

### Encryption at Rest

All secrets are encrypted using **AGE** and **SOPS**:

| Tool | Use Case | Command |
|------|----------|---------|
| **SOPS** | JSON files (structured) | `sops -e -i file.json` |
| **AGE** | Plain text/env files | `age -r <pubkey> -o file.enc file` |

**AGE Public Key:**
```
age10jj52pql3htczwt6c39v598vwjgxayaemweq2c7t5p4gp996549sq9p9c5
```

**AGE Private Key Location:** `/root/.config/sops/age/keys.txt`

### Encrypted Files

Located in `~/.secrets/`:
```
email-news-intake.json.enc   # SOPS - News intake email credentials
email-nyx.json.enc           # SOPS - Nyx email credentials
environment.env.enc          # AGE - Environment variables
google-nyx.json.enc          # SOPS - Google API credentials
linkedin.env.enc             # AGE - LinkedIn credentials
perplexity.env.enc           # AGE - Perplexity API key
readwise.json.enc            # SOPS - Readwise credentials
telegram-bot-token.enc       # AGE - Telegram bot token
```

Located in `~/.clawdbot/`:
```
clawdbot.json.enc            # SOPS - Main Clawdbot config (all API keys)
```

### Runtime Decryption

Secrets are decrypted **at boot** to a **tmpfs** mount (RAM-only, vanishes on reboot).

**Script:** `/usr/local/bin/clawdbot-start.sh`

**Flow:**
1. Mount tmpfs at `~/.clawdbot/runtime/` (2MB, mode 0700)
2. Decrypt all `.enc` files to tmpfs
3. Create symlinks from original locations → tmpfs
4. Start Clawdbot as fx user

**Decrypted runtime location:** `~/.clawdbot/runtime/`

---

## Backup Jobs

### 1. Dropbox Backup (rclone)

**Schedule:** Daily at 03:00 UTC
**Script:** `~/backup-to-dropbox.sh`

```bash
#!/bin/bash
rclone sync ~/clawd/ dropbox:nyx-backup/clawd/ --exclude '.git/**' -q
rclone sync ~/.clawdbot/ dropbox:nyx-backup/clawdbot/ \
    --exclude 'telegram/**' \
    --exclude 'agents/*/sessions/**' -q
echo "$(date): Backup completed" >> ~/backup.log
```

**What's backed up:**
- `~/clawd/` → workspace (skills, memory, config)
- `~/.clawdbot/` → Clawdbot state (excluding session logs and telegram cache)

**Excludes:**
- `.git/` directories
- `telegram/` cache
- `agents/*/sessions/` (session transcripts)

### 2. NAS Backup (rsync)

**Schedule:** Daily at 03:30 UTC
**Script:** `~/backup-to-nas.sh`
**Destination:** TerraMaster NAS at 100.98.9.111 (Tailscale)
**Protocol:** rsync daemon on port 873

**Configuration:**
- User: `rsync-user`
- Module: `Backup`
- Password file: `~/.rsync-nas-password` (chmod 600)

**What's backed up:**
- `~/clawd/` → `/Backup/nyx/clawd/`
- `~/.clawdbot/` → `/Backup/nyx/clawdbot/`

**Excludes (clawd):**
- `.git`, `.venv`, `__pycache__`, `node_modules`, `.mypy_cache`, `*.pyc`, `.pytest_cache`

**Excludes (clawdbot):**
- `telegram`, `agents/*/sessions`, `runtime`, `*.log`

**Features:**
- Telegram alert on failure
- Dry-run mode: `./backup-to-nas.sh --dry-run`
- Test mode: `./backup-to-nas.sh --test`

### 3. Security Scan

**Schedule:** Weekly, Sunday at 04:00 UTC
**Script:** `~/security-scan.sh`

---

## Crontab (fx user)

```cron
0 3 * * *   /home/fx/backup-to-dropbox.sh
30 3 * * *  /home/fx/backup-to-nas.sh
0 4 * * 0   /home/fx/security-scan.sh
```

---

## Systemd Service

**Unit:** `/etc/systemd/system/clawdbot.service`

```ini
[Unit]
Description=Clawdbot Gateway
After=network.target home-fx-.clawdbot-runtime.mount
Requires=home-fx-.clawdbot-runtime.mount

[Service]
Type=simple
Environment="XDG_RUNTIME_DIR=/run/user/1000"
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
ExecStart=/usr/local/bin/clawdbot-start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## Disaster Recovery Procedures

### Full Server Recovery

1. **Provision new Hetzner server** (Ubuntu 24.04)
2. **Restore AGE private key** from 1Password bundle
3. **Run provisioning scripts** from `moltbot-setup` repo
4. **Restore secrets** using `nyx-import-secrets.sh`
5. **Restore workspace** from Dropbox or NAS
6. **Start Clawdbot service**

### Secrets Export (for 1Password backup)

**Script:** `~/moltbot-setup/provision/nyx-export-secrets.sh`

```bash
sudo ./nyx-export-secrets.sh --output ~/nyx-secrets-bundle.tar.gz.age
```

Creates an AGE-encrypted tarball containing:
- AGE private key
- All SOPS-encrypted configs
- All AGE-encrypted secrets
- GitHub CLI credentials (encrypted)
- rclone config (encrypted)
- Manifest with checksums

**Store in 1Password** with the passphrase.

### Secrets Import (on new server)

```bash
sudo ./nyx-import-secrets.sh --bundle nyx-secrets-bundle.tar.gz.age
```

---

## Key Locations Summary

| Item | Location |
|------|----------|
| Workspace | `~/clawd/` |
| Clawdbot state | `~/.clawdbot/` |
| Encrypted secrets | `~/.secrets/*.enc` |
| Encrypted config | `~/.clawdbot/clawdbot.json.enc` |
| Runtime (tmpfs) | `~/.clawdbot/runtime/` |
| AGE private key | `/root/.config/sops/age/keys.txt` |
| SOPS config | `~/.clawdbot/.sops.yaml` |
| Boot script | `/usr/local/bin/clawdbot-start.sh` |
| Backup scripts | `~/backup-to-dropbox.sh`, `~/backup-to-nas.sh` |
| Provisioning | `~/moltbot-setup/provision/` |
| Backup logs | `~/backup.log`, `~/backup-nas.log` |

---

## Adding New Secrets

1. Create the file with sensitive data
2. Encrypt:
   - **JSON:** `sudo SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt sops -e -i file.json && mv file.json file.json.enc`
   - **Other:** `age -r age10jj52pql3htczwt6c39v598vwjgxayaemweq2c7t5p4gp996549sq9p9c5 -o file.enc file && shred -u file`
3. Add decryption to `/usr/local/bin/clawdbot-start.sh`
4. Restart: `sudo systemctl restart clawdbot`

---

## Testing

### Test NAS connectivity
```bash
~/backup-to-nas.sh --test
```

### Test backup (dry-run)
```bash
~/backup-to-nas.sh --dry-run
~/backup-to-dropbox.sh  # Check ~/backup.log after
```

### Verify Dropbox backup
```bash
rclone ls dropbox:nyx-backup/clawd/ | head
```

### Check runtime secrets
```bash
ls -la ~/.clawdbot/runtime/
```

---

## Package Tracking

All packages installed by the AI assistant are logged for auditability.

### INSTALLED.md

Location: `~/clawd/INSTALLED.md`

Format:
```markdown
| Date | Package | Method | Reason |
|------|---------|--------|--------|
| 2026-01-30 | example-pkg | apt | Needed for X feature |
```

### AGENTS.md Rule

Added to `~/clawd/AGENTS.md` under Safety section:

```markdown
## Package Installation

**Before installing ANY package** (apt, pip, npm, cargo, brew, etc.):
1. Log it in `INSTALLED.md` with date, package, method, and reason
2. Then install

No exceptions. This keeps the system auditable.
```

### Available Package Managers

| Manager | Use Case | Location |
|---------|----------|----------|
| apt | System packages | /usr/bin/apt |
| pip/uv | Python packages | ~/.local/bin/uv |
| pnpm | Node.js packages | ~/.local/share/npm-global/bin/pnpm |
| cargo | Rust packages | ~/.cargo/bin/cargo |
| brew | Extras (Linuxbrew) | /home/linuxbrew/.linuxbrew/bin/brew |

### Pre-existing Tools

Tools installed before tracking began are documented in `~/clawd/TOOLS.md` — includes modern CLI replacements (rg, fd, bat, eza, etc.) and infrastructure tools (hcloud, gh, tailscale).
