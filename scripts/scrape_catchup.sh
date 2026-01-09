#!/bin/bash
# Catch-up scraper - runs on login, scrapes any missing days
# Safe to run multiple times - checks last successful run time

NITTER_DIR="/Users/varun/Projects/nitter"
LAST_SUCCESS_FILE="$NITTER_DIR/.last_scrape_success"
LOG_FILE="$NITTER_DIR/output/scrape_catchup.log"
MIN_HOURS_BETWEEN_RUNS=6

cd "$NITTER_DIR"

# Ensure output directory exists
mkdir -p "$NITTER_DIR/output"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if we've had a successful run recently
if [ -f "$LAST_SUCCESS_FILE" ]; then
    last_success=$(cat "$LAST_SUCCESS_FILE")
    now=$(date +%s)
    hours_since=$(( (now - last_success) / 3600 ))

    if [ $hours_since -lt $MIN_HOURS_BETWEEN_RUNS ]; then
        # Too soon, exit silently
        exit 0
    fi
fi

log "Starting catch-up scrape"

# Check if accounts.txt exists
if [ ! -f "$NITTER_DIR/accounts.txt" ]; then
    log "ERROR: accounts.txt not found"
    exit 1
fi

# Track if any scrape succeeded
any_success=false

# Run the daily scraper for yesterday (complete day)
log "Scraping yesterday's tweets..."
if "$NITTER_DIR/src/scrape_daily" yesterday >> "$LOG_FILE" 2>&1; then
    any_success=true
fi

# Also scrape today (partial, will be re-scraped tomorrow)
log "Scraping today's tweets..."
if "$NITTER_DIR/src/scrape_daily" today >> "$LOG_FILE" 2>&1; then
    any_success=true
fi

# Only update success timestamp if at least one scrape worked
if [ "$any_success" = true ]; then
    date +%s > "$LAST_SUCCESS_FILE"
    log "Catch-up complete (success)"
else
    log "Catch-up failed - will retry next run"
fi
