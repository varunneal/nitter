#!/bin/bash
# Check status of the daily scraper

NITTER_DIR="/Users/varun/Projects/nitter"

echo "=== Nitter Daily Scraper Status ==="
echo ""

# Check if agent is loaded
echo "Launch Agent:"
if launchctl list 2>/dev/null | grep -q "com.nitter.scrape"; then
    echo "  Loaded: YES"
else
    echo "  Loaded: NO (run: launchctl load ~/Library/LaunchAgents/com.nitter.scrape.plist)"
fi
echo ""

# Check last successful run time
echo "Last Success:"
if [ -f "$NITTER_DIR/.last_scrape_success" ]; then
    last_run=$(cat "$NITTER_DIR/.last_scrape_success")
    last_run_date=$(date -r "$last_run" '+%Y-%m-%d %H:%M:%S')
    now=$(date +%s)
    hours_ago=$(( (now - last_run) / 3600 ))
    echo "  $last_run_date ($hours_ago hours ago)"
else
    echo "  Never succeeded"
fi
echo ""

# Check accounts and totals
echo "Accounts:"
if [ -f "$NITTER_DIR/accounts.txt" ]; then
    grep -v "^#" "$NITTER_DIR/accounts.txt" | grep -v "^$" | while read acc; do
        acc_clean=$(echo "$acc" | sed 's/@//')
        acc_dir="$NITTER_DIR/output/$acc_clean"
        if [ -d "$acc_dir" ]; then
            csv_count=$(ls "$acc_dir"/*.csv 2>/dev/null | wc -l | tr -d ' ')
            tweet_count=$(cat "$acc_dir"/*.csv 2>/dev/null | wc -l | tr -d ' ')
            tweet_count=$((tweet_count - csv_count))  # subtract headers
            echo "  @$acc_clean: $tweet_count tweets across $csv_count days"
        else
            echo "  @$acc_clean: (no data yet)"
        fi
    done
else
    echo "  No accounts.txt found!"
fi
echo ""

# Show recent log
echo "Recent Activity (last 10 lines):"
if [ -f "$NITTER_DIR/output/scrape_catchup.log" ]; then
    tail -10 "$NITTER_DIR/output/scrape_catchup.log" | sed 's/^/  /'
else
    echo "  No log yet"
fi
echo ""

# Check for errors
if [ -f "$NITTER_DIR/output/launchd_stderr.log" ]; then
    errors=$(cat "$NITTER_DIR/output/launchd_stderr.log" | tail -5)
    if [ -n "$errors" ]; then
        echo "Recent Errors:"
        echo "$errors" | sed 's/^/  /'
        echo ""
    fi
fi
