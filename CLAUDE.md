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
- Centralised monitoring hub (Beszel + Uptime Kuma) for all infrastructure

## Architecture

### Secrets Management (Three-Layer Security)

```
Layer 1: At Rest (Disk)     - ~/.openclaw/*.enc, ~/.secrets/*.enc (SOPS/AGE encrypted)
Layer 2: Runtime (RAM)      - ~/.openclaw/runtime/ (tmpfs, wiped on reboot)
Layer 3: Boot Sequence      - openclaw-start.sh decrypts to tmpfs, never to disk
```

Key insight: Secrets only exist decrypted in RAM. The tmpfs mount (`home-fx-.openclaw-runtime.mount`) ensures no disk forensics possible.

### Provisioning Flow (12 Phases)

`provision/nyx-provision.sh` orchestrates: Hetzner server creation → Base config → Security hardening → Secrets import → Package installation → Systemd setup → Workspace → Tracked packages → Mission Control → Tailscale → NAS backup → Monitoring stack → Final verification

Key insight: When `--restore-from-nas` is used, Tailscale (Phase 8) runs *before* Workspace Restore (Phase 7) since NAS is only reachable via Tailscale.

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

# Mission Control dashboard (user service)
systemctl --user status mission-control
systemctl --user restart mission-control
journalctl --user -u mission-control -f

# Monitoring stack (user services)
systemctl --user status beszel-hub
systemctl --user status beszel-agent
systemctl --user status uptime-kuma
journalctl --user -u beszel-hub -f
```

### Package Sync

```bash
./scripts/sync-packages.sh        # sync nyx-packages.txt to server
```

## Directory Structure

```
.github/workflows/  # CI/CD
  security-scan.yml    # Gitleaks secret detection (push/PR)
  auto-merge.yml       # Auto-squash nyx/* branch PRs

.githooks/          # Version-controlled git hooks
  pre-commit           # Gitleaks secret scanning

provision/          # Server provisioning automation
  nyx-provision.sh     # Main orchestrator (10 phases)
  nyx-export-bundle.sh # Export secrets locally
  nyx-import-secrets.sh# Import bundle to server
  nyx-verify.sh        # Post-install verification

mission-control/    # Next.js dashboard app (Activity, Calendar, Search)
  src/                 # App source (pages, components, lib)
  scripts/             # start.sh, reindex.sh
  data/                # SQLite DBs (runtime, git-ignored)
  DOCUMENTATION.md     # Dashboard design documentation

config/             # Systemd & decryption configuration
  openclaw.service     # Main service unit
  openclaw-runtime.mount # tmpfs mount unit
  openclaw-start.sh    # Startup: decrypt + symlink + start
  openclaw-decrypt.sh  # Decrypt wrapper (calls sudo)
  sops-decrypt-config  # SOPS decrypt helper
  mission-control.service # Dashboard systemd user service
  beszel-hub.service   # Beszel monitoring hub (port 8090)
  beszel-agent.service # Beszel metrics agent (port 45876)
  uptime-kuma.service  # Uptime Kuma service monitor (port 3001)
  nyx-packages.txt     # Package manifest

scripts/            # Operational scripts
  backup-to-dropbox.sh # Daily Dropbox sync (3:00 AM)
  backup-to-nas.sh     # Daily NAS rsync (3:30 AM, Tailscale)
  restore-from-nas.sh  # Disaster recovery from NAS
  security-scan.sh     # Weekly rkhunter scan (Sunday 4:00 AM)
  nix-update.sh        # Update Nix flake + rebuild
  nix-rollback.sh      # Rollback Nix generation
  sync-packages.sh     # Sync package manifest to server
  setup-nas-backup.sh  # NAS backup setup helper
  install-git-hooks.sh # One-time hook setup
  install-monitoring.sh # Beszel + Uptime Kuma installer
  mc-log.sh            # Mission Control activity logger
  mc-refresh-cron.sh   # Mission Control cron data refresh

security/           # Security hardening scripts
  setup-security.sh    # Master security installer
  ufw-setup.sh         # Firewall rules
  fail2ban-jail.local  # Fail2ban rules
  sshd-hardening.conf  # SSH config

nix/                # Nix + Home Manager configuration
  flake.nix            # Flake definition
  flake.lock           # Pinned versions
  packages.nix         # Package list

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
- Beszel hub data: `~/.beszel/`
- Beszel agent config: `~/.config/beszel-agent.env`
- Uptime Kuma: `~/.uptime-kuma/`
- Monitoring binaries: `~/.local/bin/beszel`, `~/.local/bin/beszel-agent`

### Bash Script Conventions

All scripts use:
- `set -euo pipefail` for strict error handling
- Colored `log_*` functions from `provision/lib/logging.sh`
- Cleanup traps for temporary files
- Idempotent design (safe to re-run)

### Logging Library (`provision/lib/logging.sh`)

Source with: `source "$(dirname "$0")/lib/logging.sh"` (or adjust path)

Logging: `log_info`, `log_success`, `log_warn`, `log_error`, `log_fatal` (exits 1), `log_step`, `log_substep`, `log_debug`

Utilities: `spinner()` (animated wait), `confirm()` (y/n prompt), `require_root`, `require_command(s)`, `require_file`, `require_dir`, `run_cmd` (log + execute), `banner`, `separator`

### CI/CD & Git Hooks

- **GitHub Actions**: `security-scan.yml` (Gitleaks on push/PR to main) + `auto-merge.yml` (auto-squash-merges PRs from `nyx/*` branches)
- **Local pre-commit hook**: Gitleaks secret scanning via `.githooks/pre-commit`
- **One-time setup**: `./scripts/install-git-hooks.sh` to activate local hooks
- **Allowlist**: `.gitleaks.toml` contains known non-secrets (AGE public keys, placeholder tokens, test keys)

### Adding New Secrets

1. Add to encrypted bundle structure in `nyx-export-bundle.sh`
2. Update `nyx-import-secrets.sh` to restore it
3. Test with `tests/test-bundle-roundtrip.sh`

### Adding Automated Tasks

1. Create script in `scripts/`
2. Add Telegram notification (see `backup-to-nas.sh` pattern)
3. Add cron entry in `nyx-provision.sh`

## Security Model

- **Network**: UFW default-deny, only SSH (22) + Tailscale (41641). Monitoring ports (8090, 3001, 45876) accessible only via Tailscale
- **SSH**: Key-only, root disabled, max 3 auth attempts, AllowUsers: fx
- **Runtime**: Secrets in tmpfs (RAM-only), never written to disk
- **Monitoring**: Fail2ban, rkhunter weekly scans, unattended security upgrades, Beszel (resource metrics), Uptime Kuma (service health)
