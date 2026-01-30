# OpenClaw DR Migration - Resume Document

**Date**: 2026-01-30
**Status**: Paused - Resume tomorrow morning

---

## Current State

### Servers

| Server | IP (Tailscale) | SSH Key | Status | Config Path | Service Name |
|--------|----------------|---------|--------|-------------|--------------|
| **nyx** (prod) | 100.64.138.99 | `~/.ssh/id_nyx` | Running | `~/.clawdbot/` | `clawdbot-gateway` |
| **nyx-dr** | 100.109.120.109 | `~/.ssh/id_nyx-dr` | Stopped | `~/.openclaw/` | `openclaw-gateway` |

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
| Naming mismatch | Prod uses `clawdbot`, DR uses `openclaw` | Needs standardization |
| NAS backup path | Was only `clawdbot/`, restore looks for `openclaw/` | Fixed - copied to `openclaw/` |
| Missing state on DR | Cron jobs, memory DB, auth profiles not restored | Manually copied (not via provisioning) |
| No SOPS/AGE on DR | DR didn't use proper secrets decryption flow | Needs reprovisioning |
| Backup script bug | References `~/.openclaw/` but prod has `~/.clawdbot/` | Needs fix |

### What Was Manually Copied to nyx-dr
These items were copied manually during troubleshooting (not via provisioning):
- `~/.openclaw/agents/main/agent/auth-profiles.json` - Anthropic OAuth tokens
- `~/.openclaw/memory/main.sqlite` - 7.4MB conversation history
- `~/.openclaw/cron/jobs.json` - 67 scheduled jobs (daily briefing, reminders)
- `~/.openclaw/devices/paired.json` - Paired devices
- `~/.openclaw/identity/device.json` - Device identity

---

## Plan for Tomorrow

### Phase 0: Add INSTALLED.md Parsing to Provisioning Script

**Goal**: Auto-install packages that Nyx installed after initial provisioning

Add function to `provision/nyx-provision.sh`:
```bash
install_tracked_packages() {
    local installed_md="$TARGET_HOME/clawd/INSTALLED.md"
    # Parse markdown table, install packages by method
}
```

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

**Current INSTALLED.md content:**
```
| 2026-01-30 | weasyprint | pip (uv) | PDF generation from HTML/CSS |
```

---

### Phase 1: Test E2E Provisioning on nyx-dr

**Goal**: Validate the provisioning script works end-to-end

```bash
# Option A: Wipe and reprovision existing server
./provision/nyx-provision.sh \
  --existing-server nyx-dr \
  --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age \
  --restore-from-nas

# Option B: Delete from Hetzner and create fresh
# (Delete nyx-dr in Hetzner console first)
./provision/nyx-provision.sh \
  --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age \
  --restore-from-nas
```

**Verification checklist**:
- [ ] SOPS/AGE decryption working (secrets in tmpfs)
- [ ] Telegram bot responds to messages
- [ ] Cron jobs loaded (should be 67 jobs)
- [ ] Memory/conversation history intact
- [ ] Backup scripts functional (`backup-to-nas.sh --test`)
- [ ] Service auto-starts on reboot

### Phase 2: Recreate Production nyx

**Goal**: Both servers identical, created by same process

```bash
# 1. Stop nyx-dr first (avoid Telegram conflict)
ssh -i ~/.ssh/id_nyx-dr fx@100.109.120.109 'systemctl --user stop openclaw-gateway'

# 2. Export fresh backup from prod to NAS
ssh -i ~/.ssh/id_nyx fx@100.64.138.99 '~/backup-to-nas.sh'

# 3. Delete nyx server from Hetzner console

# 4. Provision new nyx
./provision/nyx-provision.sh \
  --secrets-bundle ~/nyx-secrets-bundle.tar.gz.age \
  --restore-from-nas

# 5. Verify and switch traffic to new nyx
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
ssh -i ~/.ssh/id_nyx fx@100.64.138.99 'systemctl --user status clawdbot-gateway --no-pager'

# DR nyx-dr
ssh -i ~/.ssh/id_nyx-dr fx@100.109.120.109 'systemctl --user status openclaw-gateway --no-pager'
```

### Failover: Production to DR
```bash
# Stop production
ssh -i ~/.ssh/id_nyx fx@100.64.138.99 'systemctl --user stop clawdbot-gateway'

# Start DR
ssh -i ~/.ssh/id_nyx-dr fx@100.109.120.109 'systemctl --user start openclaw-gateway'
```

### Failover: DR to Production
```bash
# Stop DR
ssh -i ~/.ssh/id_nyx-dr fx@100.109.120.109 'systemctl --user stop openclaw-gateway'

# Start production
ssh -i ~/.ssh/id_nyx fx@100.64.138.99 'systemctl --user start clawdbot-gateway'
```

### Check NAS Backup Contents
```bash
ssh -i ~/.ssh/id_nyx-dr fx@100.109.120.109 \
  'rsync --list-only --password-file=$HOME/.rsync-nas-password "rsync://rsync-user@100.98.9.111/Backup/nyx/"'
```

### Test NAS Connectivity
```bash
ssh -i ~/.ssh/id_nyx-dr fx@100.109.120.109 '~/backup-to-nas.sh --test'
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
~/.config/systemd/user/openclaw-gateway.service   # Systemd service
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
