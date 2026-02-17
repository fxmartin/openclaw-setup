# Nyx Services Inventory

Complete list of custom skills, configured tools, and automations running on Nyx.

## Custom Skills (13)

Located in `~/clawd/skills/`

| Skill | Description |
|-------|-------------|
| analyst-report | Executive analyst reports on companies (PDF) |
| auto-updater | Daily auto-update for Openclaw and skills via cron |
| banking-sector-report | Country banking sector deep-dives (PDF) |
| crypto-market | Real-time crypto data + forecasts |
| flight-tracker | Live flight tracking via OpenSky |
| fx-daily-briefing | Personalized morning digest |
| humanizer | Remove AI writing patterns |
| linkedin-cli | LinkedIn CLI (`lk`) for feed, search, messages |
| perplexity | AI-powered web search via Perplexity Pro API |
| portfolio-watcher | Track stock/crypto holdings and alerts |
| professional-profile | Research individuals' backgrounds |
| remind-me | Natural language reminders via cron |
| skillcraft | Create and package Openclaw skills |

## Bundled Skills (13)

| Skill | Description |
|-------|-------------|
| clawdhub | Install/update skills from ClawdHub |
| github | GitHub CLI (`gh`) integration |
| gog | Google Workspace (Gmail, Calendar, Drive) |
| himalaya | Email via IMAP/SMTP |
| nano-banana-pro | Gemini image generation |
| notion | Notion API integration |
| openai-image-gen | OpenAI image generation |
| openai-whisper-api | Audio transcription |
| session-logs | Search session history |
| slack | Slack integration |
| tmux | Tmux session control |
| video-frames | Extract video frames (ffmpeg) |
| weather | Weather forecasts |

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
| Dec 28 annually | Controle technique reminder |

## Backup Jobs

| Schedule | Task | Script |
|----------|------|--------|
| Daily 3:00am | Dropbox sync (rclone) | `~/backup-to-dropbox.sh` |
| Daily 3:30am | NAS rsync (Tailscale) | `~/backup-to-nas.sh` |
| Sunday 4:00am | Security scan (rkhunter) | `~/security-scan.sh` |

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

- **sops + age** — Secrets encrypted at rest, decrypted to tmpfs (RAM only)
- **Dropbox backup** — Encrypted configs backed up daily
- **NAS backup** — Full state backed up via Tailscale

See [sops-age-setup.md](sops-age-setup.md) for encryption details.
