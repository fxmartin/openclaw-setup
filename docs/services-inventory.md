# Nyx Services Inventory

Complete list of custom skills, configured tools, and automations running on Nyx.

## Custom Skills

Located in `~/clawd/skills/`

| Skill | Description |
|-------|-------------|
| analyst-report | Executive analyst reports on companies |
| banking-sector-report | Country banking sector deep-dives |
| crypto-market | Real-time crypto data + forecasts |
| flight-tracker | Live flight tracking via OpenSky |
| fx-daily-briefing | Personalized morning digest |
| humanizer | Remove AI writing patterns |
| professional-profile | Research individuals' backgrounds |
| weather | Weather forecasts (built-in) |
| session-logs | Session logging and history (built-in) |

## Configured CLIs

| Tool | Purpose |
|------|---------|
| gog | Google Workspace (Gmail, Calendar, Drive) |
| gh | GitHub (repos, issues, PRs) |
| himalaya | Email via IMAP (news-intake, nyx-mail) |
| hcloud | Hetzner Cloud management |
| rclone | Dropbox backup |
| sops + age | Secrets encryption |

## Active Automations (Cron)

| Schedule | Task |
|----------|------|
| 6am weekdays, 9am weekends | Daily briefing |
| 8pm Athens time | Greek lessons |
| 5am daily | Security report (email) |
| 7pm daily | Token usage report (email) |
| Hourly | Anthropic status check |
| Periodic | YouTube monitors (IndyDevDan, Alex Ziskind) |
| 1st & 15th monthly | Calendar sync reminder |
| Dec 28 annually | Contrôle technique reminder |

## Monitoring Services

Nyx hosts the centralised monitoring hub for all infrastructure machines.

| Service | Port | Type | Purpose |
|---------|------|------|---------|
| Beszel Hub | 8090 | systemd user | System resource dashboards (CPU, RAM, disk, network, temps) |
| Uptime Kuma | 3001 | systemd user | HTTP/TCP endpoint health checks, status page, alerts |
| Beszel Agent | 45876 | systemd user | Collects local metrics and ships to hub (self-monitoring) |

### Monitored Systems

| System | Agent | Metrics |
|--------|-------|---------|
| Nyx (self) | Beszel agent | CPU, RAM, disk, network |
| MacBooks (×4) | Beszel agent (LaunchAgent) | CPU, RAM, disk, network |
| Dev server | Beszel agent (systemd user) | CPU, RAM, disk, network |

### Uptime Kuma Monitors

| Monitor | Type | Target |
|---------|------|--------|
| MacBook health-api (×4) | HTTP | `http://<tailscale-ip>:7780/ping` |
| Mission Control | HTTP | `http://localhost:3333` |
| Beszel Hub | HTTP | `http://localhost:8090` |
| Dev server SSH | TCP | `<dev-tailscale-ip>:22` |

All monitoring accessible via Tailscale only (not exposed to public internet).

## Security

- **sops + age** — Secrets encrypted at rest
- **Dropbox backup** — Keys + encrypted configs

See [sops-age-setup.md](sops-age-setup.md) for encryption details.
