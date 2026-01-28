# Nyx - FX's AI Assistant

Personal Clawdbot workspace for François-Xavier Martin.

## Skills (26 Ready)

### Workspace Skills (Custom)

| Skill | Description |
|-------|-------------|
| 📊 **analyst-report** | Generate executive analyst reports on companies (PDF) |
| 🔄 **auto-updater** | Daily auto-update for Clawdbot and skills via cron |
| 🏦 **banking-sector-report** | Banking sector reports by country (PDF) |
| 📈 **crypto-market** | Real-time crypto market data and forecasts |
| ✈️ **flight-tracker** | Live flight tracking via OpenSky Network |
| 📰 **fx-daily-briefing** | Morning news digest from newsletters/RSS |
| ✍️ **humanizer** | Remove AI writing patterns from text |
| 💼 **linkedin-cli** | LinkedIn CLI (`lk`) for feed, search, messages |
| 🔮 **perplexity** | AI-powered web search via Perplexity API |
| 📈 **portfolio-watcher** | Track stock/crypto holdings and alerts |
| 👤 **professional-profile** | Research professional backgrounds |
| ⏰ **remind-me** | Natural language reminders via cron |
| 🧶 **skillcraft** | Create and package Clawdbot skills |

### Bundled Skills (Ready)

| Skill | Description |
|-------|-------------|
| 📦 **bluebubbles** | BlueBubbles iMessage plugin |
| 📦 **clawdhub** | Install/update skills from ClawdHub |
| 📦 **github** | GitHub CLI (`gh`) integration |
| 🎮 **gog** | Google Workspace (Gmail, Calendar, Drive) |
| 📧 **himalaya** | Email via IMAP/SMTP |
| 🍌 **nano-banana-pro** | Gemini image generation |
| 📝 **notion** | Notion API integration |
| 🖼️ **openai-image-gen** | OpenAI image generation |
| ☁️ **openai-whisper-api** | Audio transcription |
| 📜 **session-logs** | Search session history |
| 📦 **skill-creator** | Create AgentSkills |
| 📦 **slack** | Slack integration |
| 🧵 **tmux** | Tmux session control |
| 🎞️ **video-frames** | Extract video frames (ffmpeg) |
| 🌤️ **weather** | Weather forecasts |

## Configured Integrations

- **Telegram** - Primary messaging channel
- **LinkedIn** - Cookie-based CLI access (`lk`)
- **Perplexity Pro** - AI web search
- **Google Workspace** - Gmail, Calendar, Drive
- **GitHub** - CLI access

## Cron Jobs

- **Daily Auto-Update** - 4:00 AM CET
- **Birthday Reminders** - 40 contacts configured

## Directory Structure

```
~/clawd/
├── AGENTS.md        # Agent behavior guide
├── SOUL.md          # Nyx persona
├── USER.md          # FX profile
├── TOOLS.md         # CLI aliases
├── MEMORY.md        # Long-term memory
├── HEARTBEAT.md     # Heartbeat tasks
├── memory/          # Daily notes
├── skills/          # Workspace skills
├── reference/       # Data files (portfolio.json)
├── .secrets/        # API keys & cookies
└── docs/            # Documentation
```

## Last Updated

2026-01-28
