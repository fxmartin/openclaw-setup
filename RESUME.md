# OpenClaw DR Migration - Resume Document

**Date**: 2026-01-31
**Status**: E2E Test Complete - nyx-dr working

---

## Current State

### Servers

| Server | IP (Tailscale) | SSH Key | Status | Config Path | Service Name |
|--------|----------------|---------|--------|-------------|--------------|
| **nyx** (prod) | 100.64.138.99 | `~/.ssh/id_nyx` | Running | `~/.clawdbot/` | `clawdbot-gateway` |
| **nyx-dr** | 100.112.184.36 | `~/.ssh/id_nyx-dr` | **Running** | `~/.openclaw/` | `openclaw` |

### What Works
- Production nyx is running the Telegram bot (@NyxFXBot)
- NAS backup contains all state at `rsync://100.98.9.111/Backup/nyx/`
  - `clawd/` - workspace
  - `clawdbot/` - original config backup
  - `openclaw/` - copy for new restore scripts
- Secrets bundle exists: `~/nyx-secrets-bundle.tar.gz.age` (created 2026-01-30 19:38)

### Issues Discovered During Migration

| Issue | Description | Status |
|-------|-------------|--------|
| Naming mismatch | Prod uses `clawdbot`, DR uses `openclaw` | Needs Phase 2 |
| NAS backup path | Was only `clawdbot/`, restore looks for `openclaw/` | ✅ Fixed |
| Missing state on DR | Cron jobs, memory DB, auth profiles not restored | ✅ Fixed (--restore-from-nas) |
| No SOPS/AGE on DR | DR didn't use proper secrets decryption flow | ✅ Fixed (E2E test) |
| Backup script bug | References `~/.openclaw/` but prod has `~/.clawdbot/` | Needs Phase 2 |

### What Was Restored via NAS (--restore-from-nas)
All state now restored automatically via provisioning script:
- `~/.openclaw/agents/main/agent/auth-profiles.json` - Anthropic OAuth tokens
- `~/.openclaw/memory/main.sqlite` - 7.4MB conversation history
- `~/.openclaw/cron/jobs.json` - 67 scheduled jobs (daily briefing, reminders)
- `~/.openclaw/devices/paired.json` - Paired devices
- `~/.openclaw/identity/device.json` - Device identity

---

## Progress

### Phase 0: Add INSTALLED.md Parsing to Provisioning Script - COMPLETED

**Goal**: Auto-install packages that Nyx installed after initial provisioning

**Implementation**: `install_tracked_packages()` function in `provision/nyx-provision.sh` (line 939)

**Method mapping:**
| INSTALLED.md Method | Install Command |
|---------------------|-----------------|
| `apt` | `apt-get install -y` |
| `pip (uv)` | `uv pip install` |
| `pip` | `pip install` |
| `pnpm` | `pnpm add -g` |
| `cargo` | `cargo install` |
| `brew` | `brew install` |
| `—` | skip (baseline) |

---

### Phase 1: Test E2E Provisioning on nyx-dr - COMPLETED

**Goal**: Validate the provisioning script works end-to-end

**Command used**:
```bash
./provision/nyx-provision.sh \
  --server-name nyx-dr \
  --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age \
  --restore-from-nas
```

**Verification checklist**:
- [x] SOPS/AGE decryption working (secrets in tmpfs)
- [x] Telegram bot responds to messages
- [x] Cron jobs loaded (67 jobs)
- [x] Memory/conversation history intact
- [x] Backup scripts functional
- [x] Service auto-starts on reboot

**Fixes applied during E2E test**:
1. `gateway run` instead of `gateway start` (foreground mode for systemd)
2. `gateway.auth.token` configured in openclaw.json
3. `OPENCLAW_GATEWAY_TOKEN` env var in start script
4. Verification script fixed for remote execution (Tailscale hostname resolution)
5. Verification script counter bug fixed (`|| true` for arithmetic)

### Phase 2: Recreate Production nyx - PENDING

**Goal**: Both servers identical, created by same process

```bash
# 1. Stop nyx-dr first (avoid Telegram conflict)
ssh nyx-dr 'sudo systemctl stop openclaw'

# 2. Export fresh backup from prod to NAS
ssh nyx '~/backup-to-nas.sh'

# 3. Delete nyx server from Hetzner
hcloud server delete nyx

# 4. Provision new nyx
./provision/nyx-provision.sh \
  --server-name nyx \
  --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age \
  --restore-from-nas

# 5. Verify and switch traffic to new nyx
./provision/nyx-verify.sh --remote nyx
```

### Phase 3: Expected End State

Both servers will have:
- Identical configuration path: `~/.openclaw/`
- Same service name: `openclaw-gateway`
- Same provisioning process
- Same backup/restore scripts
- SOPS/AGE encryption for secrets
- Easy failover between them

---

## Quick Reference Commands

### Check Server Status
```bash
# Production nyx
ssh nyx 'systemctl --user status clawdbot-gateway --no-pager'

# DR nyx-dr (system service, not user service)
ssh nyx-dr 'sudo systemctl status openclaw --no-pager'
```

### Failover: Production to DR
```bash
# Stop production
ssh nyx 'systemctl --user stop clawdbot-gateway'

# Start DR
ssh nyx-dr 'sudo systemctl start openclaw'
```

### Failover: DR to Production
```bash
# Stop DR
ssh nyx-dr 'sudo systemctl stop openclaw'

# Start production
ssh nyx 'systemctl --user start clawdbot-gateway'
```

### Check NAS Backup Contents
```bash
ssh nyx-dr 'rsync --list-only --password-file=$HOME/.rsync-nas-password "rsync://rsync-user@100.98.9.111/Backup/nyx/"'
```

### Test NAS Connectivity
```bash
ssh nyx-dr '~/backup-to-nas.sh --test'
```

### Run Verification Script
```bash
./provision/nyx-verify.sh --remote nyx-dr
```

---

## Files to Review Before Reprovisioning

| File | What to Check |
|------|---------------|
| `provision/nyx-provision.sh` | Uses `openclaw` naming throughout |
| `scripts/backup-to-nas.sh` | Paths are `~/.openclaw/` not `~/.clawdbot/` |
| `scripts/restore-from-nas.sh` | Restores to `~/.openclaw/` |
| `config/openclaw.service` | Service name is `openclaw-gateway` |
| `provision/nyx-export-bundle.sh` | Exports all required secrets |

---

## Architecture Notes

### Secrets Management (Three-Layer Security)
```
Layer 1: At Rest (Disk)     - ~/.openclaw/*.enc (SOPS/AGE encrypted)
Layer 2: Runtime (RAM)      - ~/.openclaw/runtime/ (tmpfs, wiped on reboot)
Layer 3: Boot Sequence      - openclaw-start.sh decrypts to tmpfs
```

### NAS Backup Structure
```
rsync://100.98.9.111/Backup/nyx/
├── clawd/          # Workspace (AGENTS.md, skills, briefings, etc.)
├── clawdbot/       # Original config backup (legacy name)
└── openclaw/       # Config backup (new name - copy of clawdbot)
```

### Key Paths on Server
```
~/clawd/                              # Workspace
~/.openclaw/openclaw.json             # Main config (symlink to runtime)
~/.openclaw/openclaw.json.enc         # Encrypted config
~/.openclaw/runtime/                  # Decrypted secrets (tmpfs)
~/.openclaw/memory/main.sqlite        # Conversation history
~/.openclaw/cron/jobs.json            # Scheduled jobs
~/.openclaw/agents/main/agent/auth-profiles.json  # Anthropic auth
/etc/systemd/system/openclaw.service  # Systemd service (system-level)
/usr/local/bin/openclaw-start.sh      # Start script (decrypts + runs)
~/.nix-profile/                       # Nix packages
```

---

## Decision: Containers vs VMs

**Discussed but decided against containers for now.**

Reason: The bot dynamically installs packages (pandoc, ffmpeg, etc.) at runtime. With containers, these would be lost on restart unless pre-baked into the image.

Future option: If package requirements stabilize, could move to Podman with:
```bash
OPENCLAW_DOCKER_APT_PACKAGES="pandoc ffmpeg imagemagick poppler-utils" ./docker-setup.sh
```

---

## Related Documentation

- **`docs/DR-SETUP.md`** - Comprehensive DR reference created by Nyx, covering:
  - 3-2-1 backup architecture
  - Secrets encryption (AGE/SOPS)
  - Runtime tmpfs decryption flow
  - All cron schedules and backup scripts
  - Full recovery procedures
  - Adding new secrets

## External Resources

- OpenClaw Docs: https://docs.openclaw.ai/
- OpenClaw GitHub: https://github.com/openclaw/openclaw
- Docker Setup: https://docs.openclaw.ai/install/docker
