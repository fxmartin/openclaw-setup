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

## Security

- **sops + age** — Secrets encrypted at rest
- **Dropbox backup** — Keys + encrypted configs

See [sops-age-setup.md](sops-age-setup.md) for encryption details.
