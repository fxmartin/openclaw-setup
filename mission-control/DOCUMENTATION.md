# Nyx Mission Control — Technical Documentation

**Version:** 0.1.0
**Created:** 2026-02-13
**Author:** Nyx (AI assistant for FX)
**Status:** Production (v2)

---

## 1. Overview

Mission Control is a web dashboard that provides visibility into all operations performed by Nyx, FX's AI assistant running on OpenClaw. It serves three purposes:

1. **Activity Feed** — Real-time log of every action Nyx performs (emails, searches, tool calls, cron jobs, file operations)
2. **Calendar View** — Weekly visual of all scheduled cron jobs with status indicators
3. **Global Search** — Full-text search across the entire workspace: memory files, documents, and activity history

## 2. Architecture

```
┌──────────────────────────────────────────────────┐
│                   Browser (Mac)                    │
│            http://nyx:3333                        │
└──────────────────┬───────────────────────────────┘
                   │ Tailscale VPN
                   ▼
┌──────────────────────────────────────────────────┐
│              nyx (Hetzner CX23)                   │
│                                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │         Next.js 16 (App Router)              │  │
│  │         Port 3333, bound to 0.0.0.0         │  │
│  │                                               │  │
│  │  ┌─────────┐ ┌──────────┐ ┌──────────┐     │  │
│  │  │Activity │ │ Calendar │ │  Search  │     │  │
│  │  │  Feed   │ │   View   │ │   View   │     │  │
│  │  └────┬────┘ └────┬─────┘ └────┬─────┘     │  │
│  │       │            │            │            │  │
│  │  ┌────▼────┐ ┌────▼─────┐ ┌───▼──────┐    │  │
│  │  │/api/    │ │/api/     │ │/api/     │    │  │
│  │  │activity │ │calendar  │ │search    │    │  │
│  │  └────┬────┘ └────┬─────┘ └───┬──────┘    │  │
│  │       │            │            │            │  │
│  │       ▼            ▼            ▼            │  │
│  │  ┌─────────┐ ┌──────────┐ ┌──────────┐     │  │
│  │  │ SQLite  │ │ OpenClaw │ │ SQLite   │     │  │
│  │  │   DB    │ │ cron CLI │ │ FTS5     │     │  │
│  │  └─────────┘ └──────────┘ └──────────┘     │  │
│  └─────────────────────────────────────────────┘  │
│                                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │  Data Sources                                │  │
│  │  • ~/clawd/memory/*.md (daily notes)        │  │
│  │  • ~/clawd/MEMORY.md (long-term memory)     │  │
│  │  • ~/clawd/**/*.md (all workspace docs)     │  │
│  │  • OpenClaw cron system (80+ jobs)          │  │
│  │  • Activity DB (POST from mc-log.sh)        │  │
│  └─────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

## 3. Tech Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Framework | Next.js (App Router) | 16.1.6 |
| Language | TypeScript | 5.x |
| UI | React | 19.2.3 |
| Styling | Tailwind CSS | 4.x |
| Database | SQLite via better-sqlite3 | 12.6.2 |
| Search | SQLite FTS5 (Full-Text Search) | Built-in |
| Package Manager | pnpm | — |
| Process Manager | systemd (user service) | — |
| Access | Tailscale VPN | — |

## 4. Folder Structure

```
~/clawd/mission-control/
├── DOCUMENTATION.md          # This file
├── README.md                 # Auto-generated Next.js readme
├── package.json              # Dependencies and scripts
├── pnpm-lock.yaml            # Lock file
├── pnpm-workspace.yaml       # Workspace config
├── tsconfig.json             # TypeScript config
├── next.config.ts            # Next.js config
├── next-env.d.ts             # Next.js type declarations
├── postcss.config.mjs        # PostCSS (Tailwind)
├── eslint.config.mjs         # ESLint config
│
├── data/
│   ├── mission-control.db    # SQLite database (WAL mode)
│   ├── mission-control.db-shm # WAL shared memory
│   ├── mission-control.db-wal # WAL log
│   └── cron-jobs.json        # Cached cron data (fallback)
│
├── scripts/
│   ├── start.sh              # Manual start script
│   └── reindex.sh            # Trigger workspace re-indexing
│
├── src/
│   ├── app/
│   │   ├── globals.css       # Theme variables (dark/light), scrollbar, FTS highlights
│   │   ├── layout.tsx        # Root layout (HTML shell, metadata)
│   │   ├── page.tsx          # Main SPA page (sidebar + tab routing)
│   │   ├── favicon.ico       # App icon
│   │   └── api/
│   │       ├── activity/
│   │       │   └── route.ts  # GET (list), POST (create), DELETE (clear all)
│   │       ├── calendar/
│   │       │   └── route.ts  # GET (weekly events from OpenClaw cron)
│   │       ├── search/
│   │       │   └── route.ts  # GET (full-text search across files + activity)
│   │       └── reindex/
│   │           └── route.ts  # POST (re-index workspace .md/.txt files)
│   │
│   ├── components/
│   │   ├── ActivityFeed.tsx   # Activity feed with filters, relative time, color coding
│   │   ├── CalendarView.tsx   # Weekly calendar grid + job summary panel
│   │   └── SearchView.tsx     # Search with highlighting, keyboard shortcuts
│   │
│   └── lib/
│       └── db.ts             # SQLite connection, schema migration, singleton
│
└── public/                    # Static assets (Next.js defaults)
```

### External Files

```
~/clawd/scripts/
├── mc-log.sh                 # Shell helper to POST activity entries
└── mc-refresh-cron.sh        # Refresh cron-jobs.json from OpenClaw

~/.config/systemd/user/
└── mission-control.service   # systemd user service
```

## 5. Database Schema

**File:** `data/mission-control.db` (SQLite, WAL mode)

### Table: `activity`

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PRIMARY KEY | Auto-increment ID |
| timestamp | TEXT | ISO 8601 timestamp (default: now) |
| action_type | TEXT NOT NULL | Category: tool_call, email, web_search, cron, file_op, message, api_call, system |
| description | TEXT NOT NULL | Human-readable description of the action |
| details | TEXT | JSON blob with additional context |
| status | TEXT | success, error, warning |
| duration_ms | INTEGER | Execution time in milliseconds |

**Indexes:**
- `idx_activity_timestamp` on `timestamp DESC`
- `idx_activity_type` on `action_type`

### Virtual Table: `search_index` (FTS5)

| Column | Description |
|--------|-------------|
| source | "file" or "activity" |
| path | Relative file path (for files) |
| title | Filename or action summary |
| content | Full text content |

**Tokenizer:** `porter unicode61` (stemming + unicode support)

## 6. API Reference

### GET /api/activity

List activity entries with optional filtering.

**Query Parameters:**
| Param | Type | Default | Description |
|-------|------|---------|-------------|
| type | string | (all) | Filter by action_type |
| limit | int | 50 | Max results |
| offset | int | 0 | Pagination offset |

**Response:**
```json
{
  "entries": [{ "id": 1, "timestamp": "...", "action_type": "email", "description": "...", "status": "success", "duration_ms": 1200 }],
  "total": 42,
  "todayCount": 5
}
```

### POST /api/activity

Log a new activity entry.

**Body:**
```json
{
  "action_type": "email",
  "description": "Sent daily briefing to FX",
  "status": "success",
  "duration_ms": 1200,
  "details": { "to": "mail@fxmartin.me" }
}
```

**Response:** `201 { "id": 43 }`

### DELETE /api/activity

Clear all activity entries.

**Response:** `{ "ok": true }`

### GET /api/calendar

Get weekly calendar data from OpenClaw cron system.

**Data Source:** Executes `openclaw cron list --json` with 5-minute in-memory cache. Falls back to `data/cron-jobs.json` static file if the CLI fails.

**Response:**
```json
{
  "jobs": [
    {
      "id": "uuid",
      "name": "fx-daily-briefing",
      "description": "FX Daily Briefing (weekday 6am CET)",
      "schedule": { "kind": "cron", "expr": "0 6 * * 1-5", "tz": "Europe/Luxembourg" },
      "status": "ok",
      "nextRun": "2026-02-14T05:00:00.000Z",
      "lastRun": "2026-02-13T05:00:00.000Z"
    }
  ],
  "weekEvents": [
    {
      "day": "2026-02-13",
      "hour": 6,
      "minute": 0,
      "name": "fx-daily-briefing",
      "id": "uuid",
      "schedule": "0 6 * * 1-5 @ Europe/Luxembourg",
      "status": "ok",
      "description": "FX Daily Briefing (weekday 6am CET)"
    }
  ],
  "weekStart": "2026-02-10"
}
```

**Cron expression handling:**
- Standard expressions (e.g., `0 6 * * 1-5`) → mapped to specific day/hour slots
- Interval expressions (e.g., `0 */6 * * *`) → expanded to 0, 6, 12, 18 slots
- Every-hour expressions (`* * * * *`) → skipped (too noisy for calendar)
- Day-of-week: `0` = Sunday, `1-5` = Mon-Fri, `0,6` = weekends
- Monthly jobs (specific day-of-month) → shown if they fall within the displayed week

### GET /api/search?q=term

Full-text search across indexed workspace files and activity history.

**Query Parameters:**
| Param | Type | Description |
|-------|------|-------------|
| q | string | Search query (required) |

**Response:**
```json
{
  "results": [
    {
      "source": "file",
      "path": "memory/2026-02-13.md",
      "title": "2026-02-13.md",
      "snippet": "...Mission Control <mark>dashboard</mark> with 3 features...",
      "type": "file"
    }
  ]
}
```

FTS5 handles stemming, so searching "running" matches "run", "runs", etc. Snippets include `<mark>` tags around matches.

### POST /api/reindex

Re-index all workspace files for search.

**Process:**
1. Walks `~/clawd/` recursively for `.md` and `.txt` files
2. Skips `node_modules`, hidden directories, and files > 500KB
3. Clears existing file entries from FTS index
4. Inserts each file's content into `search_index`
5. Also re-indexes activity entries

**Response:** `{ "indexed": 1550, "files": 1623 }`

## 7. Data Sources

### Activity Feed
- **Source:** HTTP POST requests to `/api/activity`
- **How to log:** Use `~/clawd/scripts/mc-log.sh`:
  ```bash
  ~/clawd/scripts/mc-log.sh "email" "Sent daily briefing" "success" 1200
  ~/clawd/scripts/mc-log.sh "web_search" "Searched Bitcoin price" "success" 500 '{"query":"btc price"}'
  ```
- **Currently:** Manual logging via script. Future: automated hook in Nyx's tool call pipeline.

### Calendar
- **Source:** OpenClaw cron system via `openclaw cron list --json`
- **Cache:** In-memory, 5-minute TTL
- **Fallback:** Static `data/cron-jobs.json` (refreshed by `mc-refresh-cron.sh`)
- **Jobs tracked (as of 2026-02-13):** 80 cron jobs including:
  - Daily briefings (weekday 6am, weekend 9am)
  - YouTube channel monitors (every 6h)
  - Security/health reports (daily 5am)
  - Greek language lessons (daily 8pm Athens)
  - Seneca daily wisdom (daily 7:30am)
  - Birthday/anniversary reminders (various dates)
  - Portfolio monitoring, reading list reminders, etc.

### Global Search
- **Source:** SQLite FTS5 virtual table indexing:
  - All `.md` and `.txt` files under `~/clawd/` (~1,550 files)
  - All activity entries from the activity table
- **Re-indexing:** Manual via UI button (🔄) or `POST /api/reindex`
- **Tokenizer:** Porter stemming with Unicode support

## 8. UI Features

### Activity Feed
- Auto-refreshes every 5 seconds (polling)
- Filterable by action type (tool_call, email, web_search, cron, file_op, message, api_call, system)
- Relative timestamps ("2m ago", "1h ago")
- Color-coded status badges (green=success, red=error, yellow=warning)
- Duration formatting (500ms, 1.2s)
- "Clear all" button with confirmation

### Calendar View
- Weekly grid showing only hours that have events (collapsed empty hours)
- Color-coded events by last run status:
  - 🟢 Green: ok/success
  - 🟡 Yellow: idle/scheduled
  - 🔴 Red: error/fail
- Event count badges on day headers
- Tooltip on hover showing job name, schedule, status, and description
- Job summary panel below the grid with all jobs listed
- Handles cron interval expressions (`*/6` expanded to individual time slots)

### Search
- Auto-focus on load
- Keyboard shortcuts: `⌘K` or `/` to focus search
- Result count display
- FTS5 snippet highlighting with `<mark>` tags
- Source indicators (📄 file, ⚡ activity)
- File path shown for file results
- Re-index button

### General
- Dark theme (default) with CSS custom properties
- Light theme available via toggle
- Responsive sidebar
- Custom scrollbar styling
- Inter font family

## 9. Theming

Themes are controlled via CSS custom properties in `globals.css`. The root `<html>` element has class `dark` by default; toggling to `light` switches all variables.

| Variable | Dark | Light |
|----------|------|-------|
| --bg-primary | #0a0a0f | #f5f5f7 |
| --bg-secondary | #12121a | #ffffff |
| --bg-card | #1a1a2e | #ffffff |
| --bg-hover | #222240 | #f0f0f4 |
| --text-primary | #e4e4f0 | #1a1a2e |
| --text-secondary | #8888a8 | #6b6b80 |
| --accent | #7c3aed | #7c3aed |
| --border | #2a2a40 | #e2e2ea |

## 10. Deployment

### Systemd Service

**File:** `~/.config/systemd/user/mission-control.service`

```ini
[Unit]
Description=Nyx Mission Control Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/fx/clawd/mission-control
Environment=PORT=3333
Environment=NODE_ENV=production
Environment=PATH=/home/fx/.nix-profile/bin:/home/fx/.local/share/npm-global/bin:/home/fx/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/fx/.local/share/npm-global/bin/pnpm start -H 0.0.0.0 -p 3333
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

**Commands:**
```bash
# Start/stop/restart
systemctl --user start mission-control
systemctl --user stop mission-control
systemctl --user restart mission-control

# Check status
systemctl --user status mission-control

# View logs
journalctl --user -u mission-control -f

# Enable on boot
systemctl --user enable mission-control

# After editing the service file
systemctl --user daemon-reload
```

**Important:** The service binds to `0.0.0.0:3333` so it's accessible via Tailscale. Access from FX's Mac: `http://nyx:3333`

### Build Process

```bash
cd ~/clawd/mission-control
pnpm install          # Install dependencies
pnpm run build        # Production build
pnpm start            # Start production server (or use systemd)
pnpm dev              # Development mode with hot reload
```

### Network Access

| From | URL |
|------|-----|
| nyx (local) | `http://localhost:3333` |
| FX's Mac (Tailscale) | `http://nyx:3333` |
| Any Tailscale device | `http://nyx:3333` |

Port 3333 is only accessible via Tailscale — not exposed to the public internet.

### Related Monitoring Dashboards

| Service | URL (Tailscale) | Purpose |
|---------|-----------------|---------|
| Beszel Hub | `http://nyx:8090` | System resource dashboards (CPU, RAM, disk, network) |
| Uptime Kuma | `http://nyx:3001` | Service availability monitoring and status page |

These run as separate systemd user services on Nyx alongside Mission Control.

## 11. Helper Scripts

### mc-log.sh — Activity Logger

**Path:** `~/clawd/scripts/mc-log.sh`

```bash
#!/bin/bash
# Usage: mc-log.sh <action_type> <description> [status] [duration_ms] [details_json]
curl -s -X POST http://localhost:3333/api/activity \
  -H 'Content-Type: application/json' \
  -d "{\"action_type\":\"$1\",\"description\":\"$2\",\"status\":\"${3:-success}\",\"duration_ms\":${4:-0},\"details\":${5:-null}}"
```

**Examples:**
```bash
mc-log.sh "email" "Sent daily briefing to FX" "success" 3500
mc-log.sh "cron" "Daily briefing completed" "success" 240000
mc-log.sh "web_search" "Searched for Bitcoin price" "success" 800 '{"query":"btc"}'
mc-log.sh "system" "Server reboot detected" "warning"
```

### mc-refresh-cron.sh — Cron Data Refresh

**Path:** `~/clawd/scripts/mc-refresh-cron.sh`

```bash
#!/bin/bash
mkdir -p /home/fx/clawd/mission-control/data
openclaw cron list --json > /home/fx/clawd/mission-control/data/cron-jobs.json 2>/dev/null
```

This is a fallback mechanism. The calendar API primarily shells out to `openclaw cron list --json` live with a 5-minute cache. This script updates the static fallback file.

## 12. Known Limitations

1. **Activity logging is manual** — Nyx must explicitly call `mc-log.sh` or POST to the API. There's no automatic interception of OpenClaw tool calls yet.
2. **Calendar shows UTC times** — Cron expressions include timezone info but the weekly grid displays raw hour values from the expression. This may differ from the actual execution time by 1-2 hours depending on DST.
3. **Search index is not auto-updated** — New files or changes require manual re-indexing via the UI button or `POST /api/reindex`.
4. **No authentication** — Anyone on the Tailscale network can access the dashboard. This is acceptable since Tailscale is already a trusted network.
5. **Single-week calendar** — No previous/next week navigation yet.

## 13. Future Improvements

1. **Automatic activity logging** — Hook into OpenClaw's event system or create a middleware that intercepts all tool calls
2. **Week navigation** — Previous/next week buttons on the calendar
3. **Job detail view** — Click a calendar event to see full cron job config, run history, and logs
4. **WebSocket updates** — Replace polling with WebSocket for real-time activity feed
5. **Dashboard metrics** — Total actions today, most common action types, average response times
6. **Mobile app** — PWA support for phone access
7. **Export** — Download activity history as CSV/JSON
8. **Alerts** — Visual notification when error-status activities are logged

## 14. Troubleshooting

### Dashboard won't load
```bash
# Check if service is running
systemctl --user status mission-control

# Check if port is in use
ss -tlnp | grep 3333

# Manual start for debugging
cd ~/clawd/mission-control && PORT=3333 pnpm start -H 0.0.0.0 -p 3333
```

### "Application error" in browser
- Ensure you're using `http://nyx:3333` (with port!)
- Check browser console for specific React errors
- Common cause: API returning unexpected data types (null where string expected)

### Calendar shows no events
```bash
# Test the API directly
curl -s http://localhost:3333/api/calendar | python3 -m json.tool | head -20

# Check if openclaw CLI works
openclaw cron list --json | head -5

# Force refresh the static file
~/clawd/scripts/mc-refresh-cron.sh
```

### Search returns no results
```bash
# Trigger re-index
curl -s -X POST http://localhost:3333/api/reindex

# Check index size
sqlite3 ~/clawd/mission-control/data/mission-control.db "SELECT COUNT(*) FROM search_index;"
```

### Database issues
```bash
# Check DB integrity
sqlite3 ~/clawd/mission-control/data/mission-control.db "PRAGMA integrity_check;"

# Check WAL mode
sqlite3 ~/clawd/mission-control/data/mission-control.db "PRAGMA journal_mode;"

# Reset (destructive!)
rm ~/clawd/mission-control/data/mission-control.db*
systemctl --user restart mission-control
```

---

*Document generated 2026-02-13 by Nyx. Last updated for v2 (activity logging, systemd, UI polish).*
