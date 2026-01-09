# Nitter Scraper - Project Documentation

Personal fork of nitter for scraping Twitter/X timelines via their unofficial API.

## Project Structure

```
nitter/
├── src/
│   ├── scrape_timeline.nim   # Main timeline scraper (adaptive windows)
│   ├── scrape_daily.nim      # Daily scraper for multiple accounts
│   ├── scrape_daemon.nim     # Continuous daemon for VM (round-robin)
│   ├── main.nim              # Simple search script
│   ├── api.nim               # Twitter GraphQL API calls
│   ├── auth.nim              # Session pool management
│   ├── types.nim             # Core types (Tweet, User, Timeline, etc.)
│   ├── query.nim             # Search query building
│   ├── parser.nim            # JSON response parsing
│   └── ...                   # Other nitter core files
├── scripts/
│   ├── scrape_catchup.sh     # Daily catch-up script (runs on login)
│   ├── scrape_status.sh      # Status checker
│   └── com.nitter.scrape.plist  # macOS Launch Agent config
├── output/
│   └── <username>/           # Per-user output folders
│       ├── YYYY-MM-DD.csv    # Daily tweet CSVs
│       ├── incomplete.txt    # Days needing re-scrape
│       └── scrape.log        # Scraping log
├── accounts.txt              # List of accounts for daily scraper
├── sessions.jsonl            # Twitter auth tokens
├── nitter.conf               # Config file
└── README.md                 # Quick reference
```

## Key Scripts

### scrape_timeline.nim
Full timeline scraper with adaptive window sizing.

```
./src/scrape_timeline <username> <start_date> <end_date|today>
```

Features:
- Adaptive windows: calculates EMA of tweets/day, adjusts search window (1-60 days)
- Target 750 tweets/window to stay under 1000 limit
- Auto-resumes from last scraped date
- Catches up to "today" before going backwards
- Handles rate limits with 15-min wait
- Tracks incomplete days (same-day scrapes) for re-scraping
- Merges new tweets with existing (preserves deleted tweets)

### scrape_daily.nim
Lightweight daily scraper for multiple accounts.

```
./src/scrape_daily [yesterday|today|YYYY-MM-DD]
```

Reads accounts from `accounts.txt`, scrapes specified day for each.

### scrape_daemon.nim
Continuous daemon for running on a VM. Round-robins through accounts indefinitely.

```
./src/scrape_daemon
```

Reads from `accounts-starts.txt` (format: `username YYYY-MM-DD`):
- Refreshes "today" for each account every 30 min
- Does historical scraping (adaptive windows) for unfinished accounts
- Round-robin: does one chunk of work per account, then moves to next
- Logs to `output/daemon.log`

### scrape_catchup.sh
Wrapper script for Launch Agent. Runs on login, scrapes yesterday + today for all accounts. Only runs if last success was >6 hours ago.

### scrape_status.sh
Shows scraper status: agent loaded, last success, tweet counts per account.

## Core Types (src/types.nim)

```nim
Tweet = object
  id*: int64
  text*: string
  time*: DateTime
  user*: User
  stats*: TweetStats      # replies, retweets, likes, views
  photos*: seq[string]
  video*: Option[Video]
  gif*: Option[Gif]
  quote*: Option[Quote]
  retweet*: Option[Tweet]

User = object
  id*: string
  username*: string
  fullname*: string
  bio*: string
  ...
```

## Key API Functions (src/api.nim)

```nim
proc getGraphTweetSearch*(query: Query; after=""): Future[Timeline]
proc getGraphUser*(username: string): Future[User]
proc getGraphTimeline*(id: string; after=""): Future[Timeline]
```

## CSV Output Format

```
id,url,time,text,replies,retweets,likes,views,media,has_quote
```

- `time`: UTC timestamp (YYYY-MM-DD HH:MM:SS)
- `media`: semicolon-separated URLs (photos, videos, gifs)
- `has_quote`: true/false

## Rate Limiting

- Each API call returns ~20 tweets
- Rate limits are per-session, per-endpoint
- NoSessionsError triggers 15-min wait
- Adaptive windows minimize requests for low-volume accounts

## Adaptive Window Algorithm

1. Calculate EMA from existing CSVs: `ema = α * today + (1-α) * ema`
2. Window size: `min(60, 750 / ema)` days
3. If search hits 1000 limit, halve window and retry
4. EMA updates as scraping progresses

## macOS Launch Agent

Install:
```bash
cp scripts/com.nitter.scrape.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.nitter.scrape.plist
```

Runs on login and daily at 9am (if awake).

## Session Setup

See: https://github.com/zedeus/nitter/wiki/Creating-session-tokens

Sessions go in `sessions.jsonl`, one JSON object per line with auth tokens.

## Compilation

```bash
nim c -d:ssl -d:release src/scrape_timeline.nim
nim c -d:ssl -d:release src/scrape_daily.nim
```
