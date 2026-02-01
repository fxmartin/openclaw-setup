# Nyx Improvements Journal

A detailed log of improvements, experiments, and enhancements made to Nyx. Each entry includes timestamp, description, implementation details, and relevant code/prompts.

**See also:** [README.md](README.md) for setup documentation.

---

## 2026-02-01 (Saturday)

### 1. Nix Autonomy Setup
**Time:** 11:18 CET  
**Category:** Infrastructure  
**Prompt:** "how could I give you control over your nix setup"

**Problem:** Nyx needed FX to approve PRs for any Nix package changes, creating a bottleneck.

**Solution:** 
1. GitHub Action to auto-merge PRs from `nyx/*` branches
2. Cron job (every 30 min) to sync repo and apply changes
3. Updated `nix-update.sh` to point directly to repo

**Implementation:**

`.github/workflows/auto-merge.yml`:
```yaml
name: Auto-merge Nyx PRs
on:
  pull_request:
    types: [opened, synchronize, reopened]
    branches: [main]
permissions:
  contents: write
  pull-requests: write
jobs:
  auto-merge:
    runs-on: ubuntu-latest
    if: startsWith(github.head_ref, 'nyx/')
    steps:
      - name: Merge PR
        run: gh pr merge --squash --delete-branch "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

`~/clawd/scripts/nix-sync.sh`:
```bash
#!/bin/bash
# Sync nix config from GitHub and apply changes
set -e
REPO_DIR="$HOME/clawd/openclaw-setup"
cd "$REPO_DIR"
OLD_COMMIT=$(git rev-parse HEAD)
export GIT_SSH_COMMAND="ssh -F $HOME/clawd/.ssh/config"
git fetch origin main --quiet
git reset --hard origin/main --quiet
NEW_COMMIT=$(git rev-parse HEAD)
if [ "$OLD_COMMIT" != "$NEW_COMMIT" ]; then
    if git diff --name-only "$OLD_COMMIT" "$NEW_COMMIT" | grep -q "^nix/"; then
        ~/nix-update.sh
    fi
fi
```

Cron entry:
```
*/30 * * * * /home/fx/clawd/scripts/nix-sync.sh
```

---

### 2. Himalaya Email Config Encryption
**Time:** 11:29 CET  
**Category:** Security  
**Prompt:** "encrypt himalaya config"

**Problem:** `~/clawd/.himalaya/config.toml` contained plaintext IMAP/SMTP passwords.

**Solution:** 
1. Encrypt config with AGE
2. Add decryption to `openclaw-start.sh`
3. Symlink to tmpfs (passwords never touch disk)

**Implementation:**

Encryption:
```bash
age -r age10jj52pql3htczwt6c39v598vwjgxayaemweq2c7t5p4gp996549sq9p9c5 \
  -o ~/.secrets/himalaya-config.toml.enc \
  ~/clawd/.himalaya/config.toml
shred -u ~/clawd/.himalaya/config.toml
```

Added to `openclaw-start.sh`:
```bash
# Decrypt himalaya config if exists
if [[ -f "$SECRETS_DIR/himalaya-config.toml.enc" ]]; then
    log "Decrypting himalaya-config.toml.enc to tmpfs"
    age -d -i "$AGE_KEY" "$SECRETS_DIR/himalaya-config.toml.enc" > "$RUNTIME_DIR/himalaya-config.toml"
    chown "$USER:$USER" "$RUNTIME_DIR/himalaya-config.toml"
    chmod 600 "$RUNTIME_DIR/himalaya-config.toml"
    
    HIMALAYA_DIR="$USER_HOME/clawd/.himalaya"
    mkdir -p "$HIMALAYA_DIR"
    ln -sf "$RUNTIME_DIR/himalaya-config.toml" "$HIMALAYA_DIR/config.toml"
fi
```

---

### 3. Portfolio Tracking System
**Time:** 11:40 CET  
**Category:** Feature  
**Prompt:** "Here are the positions in my current portfolio I want to track..."

**Problem:** FX wanted daily briefings to include actual portfolio values, not just price changes.

**Solution:**
1. Created `~/clawd/reference/portfolio.json` with positions
2. Updated `market-data.py` to calculate actual values
3. Added Yahoo Finance integration (free, no API key needed)
4. Tracks stocks + crypto with DCA schedule

**Portfolio structure:**
```json
{
  "name": "FX Portfolio (Revolut)",
  "currency": "EUR",
  "stocks": [
    {"ticker": "MWOQ.DE", "name": "Amundi S&P 500 EW ESG EUR-Hedged", "shares": 387.93},
    {"ticker": "AMEM.DE", "name": "Amundi MSCI Emerging Markets", "shares": 746.18},
    {"ticker": "MSTR", "name": "MicroStrategy", "shares": 19.67},
    {"ticker": "DFEN", "name": "VanEck Defense ETF 3x", "shares": 3.29},
    {"ticker": "AAPL", "name": "Apple", "shares": 0.78}
  ],
  "crypto": {
    "main": [
      {"symbol": "BTC", "amount": 0.042},
      {"symbol": "XRP", "amount": 940.34},
      {"symbol": "LINK", "amount": 59.56}
    ],
    "staking": [
      {"symbol": "ETH", "amount": 0.91},
      {"symbol": "SOL", "amount": 17.37}
    ]
  },
  "dca": {
    "stocks": [
      {"ticker": "AAPL", "amount": 100, "currency": "USD", "frequency": "weekly"},
      {"ticker": "DFEN", "amount": 100, "currency": "EUR", "frequency": "weekly"},
      {"ticker": "AMEM.DE", "amount": 100, "currency": "EUR", "frequency": "weekly"}
    ],
    "crypto": [
      {"symbol": "BTC", "amount": 100, "currency": "EUR", "frequency": "weekly"}
    ]
  }
}
```

Yahoo Finance integration (free):
```python
def get_yahoo_quote(symbol):
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?interval=1d&range=5d"
    data = fetch_json(url)
    result = data.get('chart', {}).get('result', [{}])[0]
    meta = result.get('meta', {})
    if meta.get('regularMarketPrice'):
        return {
            'price': round(meta['regularMarketPrice'], 2),
            'change': round(change, 2),
            'changePercent': round(change_pct, 2),
            'currency': meta.get('currency', 'USD'),
            'name': meta.get('longName', symbol),
            'source': 'yahoo'
        }
```

---

### 4. Memory Source Tagging
**Time:** 11:56 CET  
**Category:** Memory/Security  
**Prompt:** "Add memory source tagging to new entries"

**Problem:** No way to distinguish between facts from FX vs. web searches vs. inferences.

**Solution:** Added source tagging convention to AGENTS.md.

**Convention:**
```markdown
## Something FX told me
<!-- source: user -->
FX prefers morning briefings at 6am...

## Research finding
<!-- source: web -->
Bitcoin dropped due to ETF outflows (via Perplexity, 2026-02-01)...

## Skill-generated insight
<!-- source: skill:fx-daily-briefing -->
Market sentiment shifted to Extreme Fear...
```

**Tags:**
- `<!-- source: user -->` — Direct from FX (highest trust)
- `<!-- source: web -->` — From web search/fetch (verify before acting)
- `<!-- source: skill:name -->` — Generated by a skill
- `<!-- source: inferred -->` — Nyx's own inference (lowest trust)

---

### 5. Semantic Memory Structure
**Time:** 11:58 CET  
**Category:** Memory  
**Prompt:** "Implement structured memory experiment: create memory/semantic/"

**Problem:** Daily logs are raw soup. Need atomic, queryable facts.

**Research conducted:**
- Knowledge graphs (ZBrain, Zep AI) - entities + relationships
- MemGPT/Letta architecture - tiered memory (core/archival/recall)
- Basic Memory pattern - markdown with wikilinks

**Implementation:**
```
memory/semantic/
├── README.md           # Format guidelines
├── people/             # Facts about people
│   └── fx.md
├── companies/          # Company intel
├── preferences/        # FX's preferences
│   └── communication.md
├── decisions/          # Key decisions with rationale
│   └── 2026-02.md
└── relationships/      # Entity relationships
```

**Example entity file (people/fx.md):**
```markdown
# FX (François-Xavier Martin)

## Professional
<!-- source: user | verified: 2026-02-01 -->
- VP Head of Sales Europe at LTIMindtree Banking Transformation
- Sells core banking transformation services to banks

## Preferences
<!-- source: user | verified: 2026-02-01 -->
- Prefers being called "FX" (never François-Xavier)
- Morning briefings at 6am weekdays, 9am weekends
```

---

### 6. Source Health Monitoring
**Time:** 11:59 CET  
**Category:** Reliability  
**Prompt:** "Add source health monitoring to fx-daily-briefing skill"

**Problem:** Briefing could fail silently if data sources were down.

**Solution:** Created health check script that runs before briefing.

**`~/clawd/scripts/source-health-check.sh`:**
```bash
#!/bin/bash
# Check all briefing data sources
check_url() {
    local name="$1"
    local url="$2"
    response=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 "$url")
    if [[ "$response" == "200" ]]; then
        RESULTS["$name"]="ok"
    else
        RESULTS["$name"]="fail:$response"
    fi
}

check_url "RTL Luxembourg" "https://infos.rtl.lu/rss/feed/headlines.rss"
check_url "Greek Reporter" "https://greekreporter.com/feed/"
check_api "Fear & Greed" "https://api.alternative.me/fng/"
check_api "CoinGecko" "https://api.coingecko.com/api/v3/ping"
# ... more checks
```

Added to HEARTBEAT.md for daily monitoring.

---

### 7. Backup Scripts Fix
**Time:** 12:02 CET  
**Category:** Bug Fix  
**Issue:** Dropbox backup failing at 3am with "rclone not configured"

**Root cause:** Cron doesn't load nix profile, so `rclone` not in PATH.

**Fix (PR #6, #7):**
```bash
# Added to backup-to-dropbox.sh after set -euo pipefail:

# Source nix profile for rclone and other nix-managed tools
if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"
```

**Second fix:** Don't mix `-q` (quiet) and `-v` (verbose) in dry-run mode:
```bash
# Before (broken):
local rclone_opts="-q"
if [[ $DRY_RUN -eq 1 ]]; then
    rclone_opts+=" --dry-run -v"  # Conflict!
fi

# After (fixed):
local rclone_opts=""
if [[ $DRY_RUN -eq 1 ]]; then
    rclone_opts="--dry-run -v"
else
    rclone_opts="-q"
fi
```

---

### 8. Weekly Backup Verification
**Time:** 12:00 CET  
**Category:** Reliability  
**Prompt:** "Add weekly backup verification to HEARTBEAT.md"

**Added to HEARTBEAT.md:**
```markdown
## Weekly Backup Verification (Sundays)
- Check last Dropbox backup: `rclone lsl dropbox:nyx-backup/ --max-depth 1 | tail -5`
- Check last NAS sync: `ls -la ~/clawd/logs/backup-*.log | tail -1`
- Verify backup age < 48 hours
- If stale, alert FX
```

---

### 9. Overnight Self-Improvement Job
**Time:** 02:00 CET (runs nightly)  
**Category:** Automation  
**Created:** 2026-01-31

**Purpose:** Nyx autonomously researches improvements while FX sleeps.

**Cron job (`overnight-self-improvement`):**
- Runs at 2am CET
- Reads `~/clawd/protocols/overnight-improvement.md`
- Researches AI agent best practices
- Produces report at `~/clawd/reports/self-improvement/YYYY-MM-DD.md`
- Sends executive summary to Telegram

**Example output topics:**
- Memory architecture improvements
- New tools/integrations to consider
- Security hardening recommendations
- Performance optimizations

---

## Template for Future Entries

```markdown
### [N]. [Title]
**Time:** HH:MM CET  
**Category:** [Infrastructure|Security|Feature|Bug Fix|Memory|Reliability|Automation]  
**Prompt:** "[User's original request]"

**Problem:** [What issue this solves]

**Solution:** [High-level approach]

**Implementation:**
[Code blocks, config snippets, file paths]

**Files changed:**
- `path/to/file.sh` — [description]

**PRs:** #N (if applicable)
```

---

## Index by Category

### Infrastructure
- [Nix Autonomy Setup](#1-nix-autonomy-setup)

### Security
- [Himalaya Email Config Encryption](#2-himalaya-email-config-encryption)
- [Memory Source Tagging](#4-memory-source-tagging)

### Features
- [Portfolio Tracking System](#3-portfolio-tracking-system)

### Memory
- [Memory Source Tagging](#4-memory-source-tagging)
- [Semantic Memory Structure](#5-semantic-memory-structure)

### Reliability
- [Source Health Monitoring](#6-source-health-monitoring)
- [Backup Scripts Fix](#7-backup-scripts-fix)
- [Weekly Backup Verification](#8-weekly-backup-verification)

### Automation
- [Overnight Self-Improvement Job](#9-overnight-self-improvement-job)
