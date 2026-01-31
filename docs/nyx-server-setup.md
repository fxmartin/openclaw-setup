# Nyx Server Setup

> Self-documented server configuration for the Nyx OpenClaw instance.
> Last updated: 2026-01-31

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
- Telegram channel enabled
- Workspace: ~/clawd/
- Config: ~/.openclaw/
- Service: `openclaw.service` (systemd)
- Gateway mode: foreground (`gateway run`)
- Auth: `gateway.auth.token` configured
