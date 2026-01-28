# Nyx Server Setup

> Self-documented server configuration for the Nyx Clawdbot instance.
> Last updated: 2026-01-25

## Server Specifications

| Setting | Value |
|---------|-------|
| **Provider** | Hetzner Cloud |
| **Type** | CX23 (2 vCPU, 4GB RAM, 40GB SSD) |
| **Location** | Nuremberg, Germany (nbg1) |
| **OS** | Ubuntu 24.04.3 LTS |
| **Cost** | €3.50/month |
| **Hostname** | nyx |

## Security Stack
- UFW firewall (SSH + Tailscale only)
- Fail2ban (3 attempts = 24h ban)
- SSH hardened (keys only, no root)
- rkhunter (weekly rootkit scan)
- Auto security updates

## Automated Tasks
- Daily 3am: Dropbox backup
- Sunday 4am: Security scan

## Clawdbot
- Telegram channel enabled
- Workspace: ~/clawd/
- Config: ~/.clawdbot/
