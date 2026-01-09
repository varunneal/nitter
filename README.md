## Quick Start

Compile:
  nim c -d:ssl -d:release src/scrape_timeline.nim
  nim c -d:ssl -d:release src/scrape_daily.nim
  nim c -d:ssl -d:release src/scrape_daemon.nim

Scrape a user's full timeline (auto-resumes):
  ./src/scrape_timeline <username> <start_date> today

Scrape yesterday for all accounts in accounts.txt:
  ./src/scrape_daily yesterday

Run continuous daemon (for VM):
  ./src/scrape_daemon

## Important Files

accounts.txt          - Accounts for daily scraper (one per line)
accounts-starts.txt   - Accounts for daemon (format: username YYYY-MM-DD)
sessions.jsonl        - Twitter auth tokens (required)
nitter.conf           - Config file
output/<user>/        - CSV output by date
output/daemon.log     - Daemon scraper log

## Daily Auto-Scraper 

Check status:
  ./scripts/scrape_status.sh

View logs:
  tail -f output/scrape_catchup.log

Install agent:
  cp scripts/com.nitter.scrape.plist ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.nitter.scrape.plist

Uninstall:
  launchctl unload ~/Library/LaunchAgents/com.nitter.scrape.plist
  rm ~/Library/LaunchAgents/com.nitter.scrape.plist

Manual trigger:
  ./scripts/scrape_catchup.sh

## VM Daemon

Runs continuously, round-robins through accounts in accounts-starts.txt.
Refreshes "today" every 30 min, does historical scraping with adaptive windows.

Run in foreground:
  ./src/scrape_daemon

Run in background:
  nohup ./src/scrape_daemon &

View logs:
  tail -f output/daemon.log
