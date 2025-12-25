# SPDX-License-Identifier: AGPL-3.0-only
# Scrape a user's full timeline by searching day-by-day

import std/[asyncdispatch, os, strutils, strformat, options, times, algorithm, json]
import types, config, auth, api, query, apiutils

const
  maxResultsPerDay = 1000    # high limit - most users won't hit this
  delayBetweenPages = 3000   # ms between pagination requests (3s)
  delayBetweenDays = 5000    # ms between days (5s)
  outputBaseDir = "output"
  refreshTodayInterval = 2 * 60 * 60  # re-scrape "today" every 2 hours (in seconds)
  noSessionsRetryDelay = 15 * 60 * 1000  # wait 15 min if no sessions (don't probe, let rate limit expire)

var logFile: File

proc loadIncompleteDays(outputDir: string): seq[string] =
  ## Load list of days that need to be re-scraped (were scraped on the same day)
  let path = outputDir / "incomplete.txt"
  if not fileExists(path):
    return @[]
  result = @[]
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add trimmed

proc saveIncompleteDays(outputDir: string; days: seq[string]) =
  ## Save list of incomplete days
  let path = outputDir / "incomplete.txt"
  if days.len == 0:
    if fileExists(path):
      removeFile(path)
    return
  var f = open(path, fmWrite)
  defer: f.close()
  for day in days:
    f.writeLine(day)

proc markDayIncomplete(outputDir, dateStr: string) =
  ## Mark a day as incomplete (needs re-scrape next run)
  var days = loadIncompleteDays(outputDir)
  if dateStr notin days:
    days.add dateStr
    saveIncompleteDays(outputDir, days)

proc markDayComplete(outputDir, dateStr: string) =
  ## Mark a day as complete (remove from incomplete list)
  var days = loadIncompleteDays(outputDir)
  let idx = days.find(dateStr)
  if idx >= 0:
    days.delete(idx)
    saveIncompleteDays(outputDir, days)

proc log(msg: string) =
  let timestamp = now().utc.format("yyyy-MM-dd HH:mm:ss")
  let line = fmt"[{timestamp}] {msg}"
  logFile.writeLine(line)
  logFile.flushFile()

proc showSessionHealth() =
  let health = getSessionPoolHealth()
  let total = health{"sessions", "total"}.getInt
  let limited = health{"sessions", "limited"}.getInt
  let reqs = health{"requests", "total"}.getInt
  echo fmt"[Sessions: {total - limited}/{total} globally available, {reqs} reqs made]"
  # Note: sessions can still be rate-limited per-API even if globally available

proc escapeCsv(s: string): string =
  ## Escape a string for CSV (handle quotes, newlines, commas)
  result = s
  if result.contains('"') or result.contains(',') or result.contains('\n') or result.contains('\r'):
    result = result.replace("\"", "\"\"")
    result = "\"" & result & "\""

proc getMediaUrls(tweet: Tweet): string =
  ## Get all media URLs as semicolon-separated string
  var urls: seq[string] = @[]

  for photo in tweet.photos:
    urls.add fmt"https://pbs.twimg.com/{photo}"

  if tweet.video.isSome:
    let video = tweet.video.get
    for v in video.variants:
      if v.url.len > 0 and v.contentType == mp4:
        urls.add v.url
        break  # Just get the first mp4 variant

  if tweet.gif.isSome:
    urls.add tweet.gif.get.url

  return urls.join(";")

proc tweetToCsvRow(tweet: Tweet): string =
  ## Convert a tweet to a CSV row
  let
    id = $tweet.id
    url = fmt"https://x.com/{tweet.user.username}/status/{tweet.id}"
    time = tweet.time.format("yyyy-MM-dd HH:mm:ss")
    text = tweet.text.escapeCsv
    replies = $tweet.stats.replies
    retweets = $tweet.stats.retweets
    likes = $tweet.stats.likes
    views = $tweet.stats.views
    media = tweet.getMediaUrls.escapeCsv
    hasQuote = if tweet.quote.isSome: "true" else: "false"

  return @[id, url, time, text, replies, retweets, likes, views, media, hasQuote].join(",")

proc getCsvHeader(): string =
  return "id,url,time,text,replies,retweets,likes,views,media,has_quote"

proc loadExistingTweetIds(csvPath: string): seq[int64] =
  ## Load tweet IDs from an existing CSV file
  result = @[]
  if not fileExists(csvPath):
    return
  var first = true
  for line in lines(csvPath):
    if first:
      first = false  # Skip header
      continue
    if line.len == 0:
      continue
    # ID is the first column (before first comma)
    let commaPos = line.find(',')
    if commaPos > 0:
      try:
        result.add parseBiggestInt(line[0..<commaPos])
      except:
        discard

proc loadExistingCsvLines(csvPath: string): seq[string] =
  ## Load all data lines from an existing CSV (excluding header)
  result = @[]
  if not fileExists(csvPath):
    return
  var first = true
  for line in lines(csvPath):
    if first:
      first = false  # Skip header
      continue
    if line.len > 0:
      result.add line

proc findScrapedDateRange(outputDir: string): tuple[earliest, latest: Option[DateTime]] =
  ## Scan output directory for existing CSVs and find date range
  if not dirExists(outputDir):
    return (none(DateTime), none(DateTime))

  var
    earliestDate: Option[DateTime] = none(DateTime)
    latestDate: Option[DateTime] = none(DateTime)

  for file in walkFiles(outputDir / "*.csv"):
    let filename = extractFilename(file)
    if filename.len >= 10:  # "YYYY-MM-DD.csv"
      try:
        let dateStr = filename[0..9]
        let date = parse(dateStr, "yyyy-MM-dd")
        if earliestDate.isNone or date < earliestDate.get:
          earliestDate = some(date)
        if latestDate.isNone or date > latestDate.get:
          latestDate = some(date)
      except:
        discard  # Skip files that don't match date pattern

  return (earliestDate, latestDate)

proc scrapeDay(username, date: string): Future[seq[Tweet]] {.async.} =
  ## Scrape all tweets from a user on a specific day
  var searchQuery = Query(
    kind: QueryKind.tweets,
    text: "",
    fromUser: @[username],
    since: date,
    until: date  # Same day - API interprets as that full day
  )

  var
    cursor = ""
    tweets: seq[Tweet] = @[]
    pageNum = 1

  # For single-day search, we need to set until to the next day
  let
    dateTime = parse(date, "yyyy-MM-dd")
    nextDay = (dateTime + 1.days).format("yyyy-MM-dd")

  searchQuery.until = nextDay

  while tweets.len < maxResultsPerDay:
    let results = await getGraphTweetSearch(searchQuery, cursor)

    if results.content.len == 0:
      break

    for batch in results.content:
      for tweet in batch:
        tweets.add tweet
        if tweets.len >= maxResultsPerDay:
          break
      if tweets.len >= maxResultsPerDay:
        break

    if results.bottom.len == 0:
      break

    cursor = results.bottom
    inc pageNum
    await sleepAsync(delayBetweenPages)

  return tweets

proc writeDayCsv(outputDir, dateStr: string; tweets: var seq[Tweet]; merge = false): int =
  ## Write tweets to a daily CSV file, returns count written
  ## If merge=true, preserve existing tweets not in new batch (handles deleted tweets)
  let csvPath = outputDir / fmt"{dateStr}.csv"

  var existingLines: seq[string] = @[]
  var existingIds: seq[int64] = @[]

  if merge and fileExists(csvPath):
    existingIds = loadExistingTweetIds(csvPath)
    existingLines = loadExistingCsvLines(csvPath)

  # If no new tweets and no existing data, nothing to write
  if tweets.len == 0 and existingLines.len == 0:
    return 0

  # Sort new tweets by time (oldest first)
  tweets.sort(proc(a, b: Tweet): int = cmp(a.time, b.time))

  # Build set of new tweet IDs for quick lookup
  var newIds: seq[int64] = @[]
  for tweet in tweets:
    newIds.add tweet.id

  var csvFile = open(csvPath, fmWrite)
  defer: csvFile.close()

  csvFile.writeLine(getCsvHeader())

  # Write new tweets first (they have fresher stats)
  for tweet in tweets:
    csvFile.writeLine(tweetToCsvRow(tweet))

  # Append old tweets that weren't in the new batch (possibly deleted)
  var preservedCount = 0
  if merge:
    for i, oldId in existingIds:
      if oldId notin newIds:
        csvFile.writeLine(existingLines[i])
        inc preservedCount

  let totalCount = tweets.len + preservedCount
  if preservedCount > 0:
    echo fmt"  (preserved {preservedCount} previously-captured tweets)"

  return totalCount

proc scrapeTimeline(username: string; startDate, endDate: DateTime; outputDir: string; backwards = true; skipDays: seq[string] = @[]) {.async.} =
  ## Scrape a user's timeline day by day, outputting daily CSV files
  ## skipDays: list of dates to skip (already processed in this run)
  let today = now().utc
  var
    currentDate = if backwards: endDate else: startDate
    totalTweets = 0
    daysProcessed = 0
    daysWithTweets = 0
    lastTodayRefresh = epochTime()
    currentMonth = currentDate.format("yyyy-MM")

  # If end date is today or in future, we'll keep refreshing "today"
  let trackingToday = endDate >= today

  let direction = if backwards: "backwards" else: "forwards"
  if backwards:
    echo fmt"Scraping @{username} from {endDate.format(""yyyy-MM-dd"")} backwards to {startDate.format(""yyyy-MM-dd"")}"
  else:
    echo fmt"Scraping @{username} from {startDate.format(""yyyy-MM-dd"")} forwards to {endDate.format(""yyyy-MM-dd"")}"

  if trackingToday and backwards:
    echo fmt"(Will refresh today's tweets every {refreshTodayInterval div 3600} hours)"
  echo fmt"Output directory: {outputDir}"
  echo ""

  let targetDate = if backwards: startDate else: endDate
  log fmt"START {direction}: @{username} from {currentDate.format(""yyyy-MM-dd"")} to {targetDate.format(""yyyy-MM-dd"")}"
  showSessionHealth()

  while (backwards and currentDate >= startDate) or (not backwards and currentDate <= endDate):
    let dateStr = currentDate.format("yyyy-MM-dd")
    let todayStr = now().utc.format("yyyy-MM-dd")
    let isToday = dateStr == todayStr

    # Skip days we already processed in this run
    if dateStr in skipDays:
      if backwards:
        currentDate = currentDate - 1.days
      else:
        currentDate = currentDate + 1.days
      continue

    # Check for month milestone (going backwards)
    let thisMonth = currentDate.format("yyyy-MM")
    if thisMonth != currentMonth:
      log fmt"MONTH: reached {thisMonth} (total: {totalTweets} tweets)"
      currentMonth = thisMonth

    try:
      var tweets = await scrapeDay(username, dateStr)
      let count = writeDayCsv(outputDir, dateStr, tweets)

      # Track incomplete days: if scraped today, mark incomplete for re-scrape
      if isToday:
        markDayIncomplete(outputDir, dateStr)
      else:
        markDayComplete(outputDir, dateStr)

      if count > 0:
        totalTweets += count
        inc daysWithTweets
        if count >= maxResultsPerDay:
          echo fmt"{dateStr}: {count} tweets (total: {totalTweets}) [TRUNCATED - hit limit!]"
          log fmt"TRUNCATED: {dateStr} hit {count} tweets limit"
        else:
          echo fmt"{dateStr}: {count} tweets (total: {totalTweets})"
      else:
        # Print progress every 7 days even if no tweets
        if daysProcessed mod 7 == 0:
          echo fmt"{dateStr}: 0 tweets (total: {totalTweets})"

      inc daysProcessed

    except RateLimitError:
      echo fmt"{dateStr}: Rate limited! Waiting 60s..."
      showSessionHealth()
      log fmt"RATE_LIMIT: {dateStr} - waiting 60s"
      await sleepAsync(60000)
      # Retry the same day
      continue
    except NoSessionsError:
      echo fmt"{dateStr}: No sessions available (API rate limited). Waiting 15 min..."
      log fmt"NO_SESSIONS: {dateStr} - waiting 15 min"
      await sleepAsync(noSessionsRetryDelay)
      continue
    except Exception as e:
      echo fmt"{dateStr}: Error - {e.msg}"
      log fmt"ERROR: {dateStr} - {e.msg}"
      inc daysProcessed

    # Move to next date
    if backwards:
      currentDate = currentDate - 1.days
    else:
      currentDate = currentDate + 1.days

    # Check if we should refresh "today" (only when going backwards)
    if trackingToday and backwards and not isToday:
      let elapsed = epochTime() - lastTodayRefresh
      if elapsed >= refreshTodayInterval.float:
        let refreshTodayStr = now().utc.format("yyyy-MM-dd")
        echo fmt"[Refreshing today: {refreshTodayStr}]"
        try:
          var todayTweets = await scrapeDay(username, refreshTodayStr)
          let count = writeDayCsv(outputDir, refreshTodayStr, todayTweets, merge=true)
          if count > 0:
            echo fmt"  -> {count} tweets today"
        except:
          echo fmt"  -> Failed to refresh today"
        lastTodayRefresh = epochTime()

    await sleepAsync(delayBetweenDays)

  echo ""
  echo fmt"Done! Scraped {totalTweets} tweets over {daysProcessed} days ({daysWithTweets} days with tweets)"
  echo fmt"Output saved to: {outputDir}/"
  log fmt"DONE: {totalTweets} tweets over {daysProcessed} days"

proc main() {.async.} =
  let args = commandLineParams()

  if args.len < 3:
    echo "Usage: scrape_timeline <username> <start_date> <end_date>"
    echo "  start_date/end_date format: YYYY-MM-DD"
    echo "  Use 'today' for end_date to track ongoing tweets"
    echo ""
    echo "Example: scrape_timeline elonmusk 2024-01-01 today"
    echo ""
    echo "Output: output/<username>/<date>.csv"
    echo ""
    echo "Auto-resumes from last scraped date if output folder exists."
    quit(1)

  let
    username = args[0]
    requestedStartDate = parse(args[1], "yyyy-MM-dd")
    endDate = if args[2].toLowerAscii == "today":
                now().utc
              else:
                parse(args[2], "yyyy-MM-dd")
    outputDir = outputBaseDir / username

  # Create output directory
  createDir(outputDir)

  # Load config first
  let configPath = if fileExists("nitter.conf"): "nitter.conf"
                   elif fileExists("nitter.example.conf"): "nitter.example.conf"
                   else: ""

  if configPath.len == 0:
    echo "Error: No config file found"
    quit(1)

  let sessionsPath = "sessions.jsonl"
  if not fileExists(sessionsPath):
    echo fmt"Error: {sessionsPath} not found"
    quit(1)

  let (cfg, _) = getConfig(configPath)
  initSessionPool(cfg, sessionsPath)

  # Open log file (append mode)
  let logPath = outputDir / "scrape.log"
  logFile = open(logPath, fmAppend)
  defer: logFile.close()

  # Check for existing progress and auto-resume
  let (earliestScraped, latestScraped) = findScrapedDateRange(outputDir)

  # First, catch up from latest scraped date to today (if needed)
  let todayStr = now().utc.format("yyyy-MM-dd")
  let isEndDateToday = endDate.format("yyyy-MM-dd") == todayStr

  # Track days we've already re-scraped in this run (to avoid double-processing)
  var processedDays: seq[string] = @[]

  # Re-scrape any incomplete days (days that were scraped on the same day they represent)
  let incompleteDays = loadIncompleteDays(outputDir)
  if incompleteDays.len > 0:
    echo fmt"Found {incompleteDays.len} incomplete day(s) to re-scrape: {incompleteDays.join("", "")}"
    log fmt"INCOMPLETE: re-scraping {incompleteDays.len} days"
    for dateStr in incompleteDays:
      echo fmt"Re-scraping incomplete day: {dateStr}..."
      try:
        var tweets = await scrapeDay(username, dateStr)
        let count = writeDayCsv(outputDir, dateStr, tweets, merge=true)
        echo fmt"  {dateStr}: {count} tweets"
        processedDays.add dateStr
        # Mark complete if it's no longer today
        if dateStr != todayStr:
          markDayComplete(outputDir, dateStr)
        await sleepAsync(delayBetweenDays)
      except Exception as e:
        echo fmt"  {dateStr}: Error - {e.msg}"
        log fmt"INCOMPLETE_ERROR: {dateStr} - {e.msg}"
    echo ""

  if latestScraped.isSome:
    let latest = latestScraped.get
    if latest < endDate:
      echo fmt"Found existing data from {earliestScraped.get.format(""yyyy-MM-dd"")} to {latest.format(""yyyy-MM-dd"")}"
      echo fmt"Catching up from {latest.format(""yyyy-MM-dd"")} to {endDate.format(""yyyy-MM-dd"")}..."
      echo ""
      log fmt"CATCHUP: {latest.format(""yyyy-MM-dd"")} to {endDate.format(""yyyy-MM-dd"")}"
      # Scrape forward from latest+1 day to endDate
      let catchupStart = latest + 1.days
      if catchupStart <= endDate:
        await scrapeTimeline(username, catchupStart, endDate, outputDir, backwards=false, skipDays=processedDays)
        echo ""
        echo "Catch-up complete. Now continuing backwards..."
        echo ""
    elif isEndDateToday and todayStr notin processedDays:
      # Always refresh today even if we have it (unless already done as incomplete)
      echo fmt"Refreshing today ({todayStr})..."
      log fmt"REFRESH: {todayStr}"
      var todayTweets = await scrapeDay(username, todayStr)
      let count = writeDayCsv(outputDir, todayStr, todayTweets, merge=true)
      markDayIncomplete(outputDir, todayStr)  # Today is always incomplete
      echo fmt"Today: {count} tweets"
      echo ""
      processedDays.add todayStr

  # Now scrape backwards from earliest (or today if no existing data) to start
  var effectiveEndDate = endDate
  if earliestScraped.isSome:
    let earliest = earliestScraped.get
    if earliest > requestedStartDate:
      effectiveEndDate = earliest
      echo fmt"Resuming backwards from {effectiveEndDate.format(""yyyy-MM-dd"")} to {requestedStartDate.format(""yyyy-MM-dd"")}"
      echo ""

  echo ""
  await scrapeTimeline(username, requestedStartDate, effectiveEndDate, outputDir, skipDays=processedDays)

when isMainModule:
  waitFor main()
