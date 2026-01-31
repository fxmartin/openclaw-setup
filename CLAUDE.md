# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**openclaw-setup** is infrastructure-as-code for **Nyx**, a self-hosted Telegram bot powered by [OpenClaw](https://github.com/openclaw/openclaw). The project automates:
- Complete server provisioning on Hetzner Cloud (CPX22, Ubuntu 24.04)
- Secret encryption/decryption using SOPS + AGE with tmpfs-based runtime storage
- Security hardening (UFW, Fail2ban, SSH hardening, rkhunter)
- Dual backup strategy (Dropbox + NAS via Tailscale)
- Systemd service management with strict security policies
- Declarative package management via Nix + Home Manager

## Architecture

### Secrets Management (Three-Layer Security)

```
Layer 1: At Rest (Disk)     - ~/.openclaw/*.enc, ~/.secrets/*.enc (SOPS/AGE encrypted)
Layer 2: Runtime (RAM)      - ~/.openclaw/runtime/ (tmpfs, wiped on reboot)
Layer 3: Boot Sequence      - openclaw-start.sh decrypts to tmpfs, never to disk
```

Key insight: Secrets only exist decrypted in RAM. The tmpfs mount (`home-fx-.openclaw-runtime.mount`) ensures no disk forensics possible.

### Provisioning Flow (9 Phases)

`provision/nyx-provision.sh` orchestrates: Hetzner server creation → Base config → Security hardening → Secrets import → Package installation → Systemd setup → Workspace → Tailscale → NAS backup

### Secrets Bundle Format

Encrypted bundles (`*.tar.gz.age`) contain AGE keys, SOPS-encrypted configs, and credentials. Export with `nyx-export-bundle.sh`, import with `nyx-import-secrets.sh`.

## Key Commands

### Provisioning & Deployment

```bash
# Clone existing bot from NAS (disaster recovery - recommended)
./provision/nyx-provision.sh --secrets-bundle ~/bundle.tar.gz.age --restore-from-nas

# Brand new bot (fresh installation)
./provision/nyx-provision.sh --secrets-bundle ~/bundle.tar.gz.age --fresh

# Default: restore workspace from Dropbox
./provision/nyx-provision.sh --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age

# Provision existing server with NAS restore
./provision/nyx-provision.sh --existing-server nyx --secrets-bundle ~/bundle.tar.gz.age --restore-from-nas

# Export secrets bundle (recommended - run locally)
./provision/nyx-export-bundle.sh

# Verify provisioning
./provision/nyx-verify.sh              # local
./provision/nyx-verify.sh --remote nyx # remote
```

### Testing

```bash
# Test secrets bundle roundtrip
./tests/test-bundle-roundtrip.sh

# Dry-run backup
./scripts/backup-to-nas.sh --dry-run

# Test NAS connectivity
./scripts/backup-to-nas.sh --test

# Restore from NAS (disaster recovery)
./scripts/restore-from-nas.sh --dry-run  # Preview first!
./scripts/restore-from-nas.sh --list     # List available backups
./scripts/restore-from-nas.sh            # Perform restore
```

### Service Management (on Nyx)

```bash
sudo systemctl status openclaw
sudo systemctl restart openclaw
sudo journalctl -u openclaw -f
mount | grep runtime              # verify tmpfs
ls -la ~/.openclaw/runtime/       # verify secrets decrypted
```

### Package Sync

```bash
./scripts/sync-packages.sh        # sync nyx-packages.txt to server
```

## Directory Structure

```
provision/          # Server provisioning automation
  nyx-provision.sh     # Main orchestrator (9 phases)
  nyx-export-bundle.sh # Export secrets locally
  nyx-import-secrets.sh# Import bundle to server
  nyx-verify.sh        # Post-install verification

config/             # Systemd & decryption configuration
  openclaw.service     # Main service unit
  openclaw-runtime.mount # tmpfs mount unit
  openclaw-start.sh    # Startup: decrypt + symlink + start
  nyx-packages.txt     # Package manifest (34 packages)

scripts/            # Operational scripts
  backup-to-dropbox.sh # Daily Dropbox sync (3:00 AM)
  backup-to-nas.sh     # Daily NAS rsync (3:30 AM, Tailscale)
  restore-from-nas.sh  # Disaster recovery from NAS
  security-scan.sh     # Weekly rkhunter scan (Sunday 4:00 AM)

security/           # Security hardening scripts
  setup-security.sh    # Master security installer
  ufw-setup.sh         # Firewall rules

docs/               # Documentation
tests/              # Integration tests
```

## Configuration Patterns

### Paths on Nyx Server

- Installation: `~/clawd/`
- Encrypted config: `~/.openclaw/openclaw.json.enc`
- Runtime secrets: `~/.openclaw/runtime/` (tmpfs)
- Systemd service: `/etc/systemd/system/openclaw.service`
- Start script: `/usr/local/bin/openclaw-start.sh`
- AGE key (root): `/root/.config/sops/age/keys.txt`

### Bash Script Conventions

All scripts use:
- `set -euo pipefail` for strict error handling
- Colored `log_*` functions from `provision/lib/logging.sh`
- Cleanup traps for temporary files
- Idempotent design (safe to re-run)

### Adding New Secrets

1. Add to encrypted bundle structure in `nyx-export-bundle.sh`
2. Update `nyx-import-secrets.sh` to restore it
3. Test with `tests/test-bundle-roundtrip.sh`

### Adding Automated Tasks

1. Create script in `scripts/`
2. Add Telegram notification (see `backup-to-nas.sh` pattern)
3. Add cron entry in `nyx-provision.sh`

## Security Model

- **Network**: UFW default-deny, only SSH (22) + Tailscale (41641)
- **SSH**: Key-only, root disabled, max 3 auth attempts, AllowUsers: fx
- **Runtime**: Secrets in tmpfs (RAM-only), never written to disk
- **Monitoring**: Fail2ban, rkhunter weekly scans, unattended security upgrades
