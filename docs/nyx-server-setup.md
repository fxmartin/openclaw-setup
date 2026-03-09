# Nyx Server Setup

> Self-documented server configuration for the Nyx OpenClaw instance.
> Last updated: 2026-03-09

## Server Specifications

| Setting | Value |
|---------|-------|
| **Provider** | Hetzner Cloud |
| **Type** | CPX22 (3 vCPU AMD, 4GB RAM, 80GB SSD) |
| **Location** | Nuremberg, Germany (nbg1) |
| **OS** | Ubuntu 24.04.3 LTS |
| **Cost** | €5.98/month |
| **Hostname** | nyx |

## Package Management

| Component | Method |
|-----------|--------|
| **Primary** | Nix + Home Manager (declarative) |
| **Node.js** | via Nix |
| **Python (uv)** | via Nix |
| **System** | apt (minimal) |

## Security Stack
- UFW firewall (SSH + Tailscale only)
- Fail2ban (3 attempts = 24h ban)
- SSH hardened (keys only, no root)
- rkhunter (weekly rootkit scan)
- Auto security updates
- Secrets in tmpfs (RAM-only)

## Automated Tasks
- Daily 3:00am: Dropbox backup
- Daily 3:30am: NAS backup (Tailscale)
- Sunday 4:00am: Security scan

## OpenClaw
- Version: 2026.3.7
- Telegram channel enabled (@NyxFXBot)
- Source: ~/openclaw-git/ (npm linked globally via `npm install -g .`)
- Workspace: ~/clawd/
- Config: ~/.openclaw/
- Service: `openclaw.service` (systemd, `User=fx`)
- Gateway mode: foreground (`gateway run --force`)
- Auth: `gateway.auth.token` configured
- Upgrade: `./scripts/upgrade-openclaw.sh --tag <version>` (from local machine)

### Service Architecture
- `Type=simple` with `User=fx` — gateway runs in true foreground
- `OPENCLAW_NO_RESPAWN=1` prevents the gateway from forking a detached child
- `ExecStartPre=+openclaw-start.sh` runs as root to decrypt secrets to tmpfs
- `ExecStart=openclaw gateway run` runs as `User=fx`
- `Restart=on-failure` with `RestartSec=10` for resilience
- `ReadWritePaths` includes ~/openclaw-git for runtime writes
- IMPORTANT: The old user-level service (`systemctl --user openclaw-gateway`)
  must be disabled — it was installed by `openclaw gateway install` and competes
  for port 18789, causing restart loops

### Upgrade Notes
- Built-in `openclaw update` fails due to `ProtectHome=read-only`
- Use `./scripts/upgrade-openclaw.sh` instead (runs via SSH, outside systemd)
- After checkout, `npm run build` is required to regenerate `dist/plugin-sdk/`
- Build requires `pnpm` (installed globally if missing)
- Always prefer tagged releases; verify changelog before major jumps

## Monitoring Stack
- Beszel Hub: `beszel-hub.service` (user) — port 8090, resource dashboards
- Beszel Agent: `beszel-agent.service` (user) — port 45876, self-monitoring
- Uptime Kuma: `uptime-kuma.service` (user) — port 3001, service health
- Data: `~/.beszel/`, `~/.uptime-kuma/`
- Binaries: `~/.local/bin/beszel`, `~/.local/bin/beszel-agent`
- Installer: `scripts/install-monitoring.sh`
- Accessible via Tailscale only
