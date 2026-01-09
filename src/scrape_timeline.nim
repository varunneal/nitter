# SPDX-License-Identifier: AGPL-3.0-only
# Scrape a user's full timeline by searching day-by-day

import std/[asyncdispatch, os, strutils, strformat, options, times, algorithm, json]
import types, config, auth, api, query, apiutils

const
  maxResultsPerWindow = 1000  # hard limit before truncation
  targetTweetsPerWindow = 750 # aim for this many tweets per search (buffer below 1000)
  delayBetweenPages = 3000    # ms between pagination requests (3s)
  delayBetweenWindows = 5000  # ms between search windows (5s)
  maxWindowDays = 60          # max days to search at once
  minWindowDays = 1           # minimum window (fallback)
  defaultEma = 10.0           # default tweets/day if no data
  emaAlpha = 0.3              # EMA smoothing factor (higher = more weight to recent)
  outputBaseDir = "output"
  refreshTodayInterval = 2 * 60 * 60  # re-scrape "today" every 2 hours (in seconds)
  noSessionsRetryDelay = 15 * 60 * 1000  # wait 15 min if no sessions

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

proc ensureHttps(url: string): string =
  ## Ensure URL has https:// prefix
  if url.startsWith("https://") or url.startsWith("http://"):
    return url
  elif url.startsWith("//"):
    return "https:" & url
  else:
    return "https://" & url

proc getMediaUrls(tweet: Tweet): string =
  ## Get all media URLs as semicolon-separated string
  var urls: seq[string] = @[]

  for photo in tweet.photos:
    urls.add fmt"https://pbs.twimg.com/{photo}"

  if tweet.video.isSome:
    let video = tweet.video.get
    for v in video.variants:
      if v.url.len > 0 and v.contentType == mp4:
        urls.add v.url.ensureHttps
        break  # Just get the first mp4 variant

  if tweet.gif.isSome:
    urls.add tweet.gif.get.url.ensureHttps

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

proc calculateEma(outputDir: string): float =
  ## Calculate exponential moving average of tweets per day from existing CSVs
  ## Returns defaultEma if no data available
  if not dirExists(outputDir):
    return defaultEma

  # Collect (date, tweetCount) pairs sorted by date
  var dayCounts: seq[tuple[date: DateTime, count: int]] = @[]

  for file in walkFiles(outputDir / "*.csv"):
    let filename = extractFilename(file)
    if filename.len >= 10:
      try:
        let dateStr = filename[0..9]
        let date = parse(dateStr, "yyyy-MM-dd")
        # Count lines minus header
        var lineCount = 0
        for _ in lines(file):
          inc lineCount
        let tweetCount = max(0, lineCount - 1)
        dayCounts.add (date, tweetCount)
      except:
        discard

  if dayCounts.len == 0:
    return defaultEma

  # Sort by date (oldest first)
  dayCounts.sort(proc(a, b: tuple[date: DateTime, count: int]): int = cmp(a.date, b.date))

  # Calculate EMA
  var ema = dayCounts[0].count.float
  for i in 1..<dayCounts.len:
    ema = emaAlpha * dayCounts[i].count.float + (1.0 - emaAlpha) * ema

  # Return at least 1.0 to avoid division by zero
  return max(1.0, ema)

proc calculateWindowDays(ema: float): int =
  ## Calculate optimal window size based on EMA
  let windowDays = int(targetTweetsPerWindow.float / ema)
  return max(minWindowDays, min(maxWindowDays, windowDays))

proc splitTweetsByDay(tweets: seq[Tweet]): seq[tuple[date: string, tweets: seq[Tweet]]] =
  ## Group tweets by their date (UTC)
  var byDay: seq[tuple[date: string, tweets: seq[Tweet]]] = @[]
  var currentDate = ""
  var currentTweets: seq[Tweet] = @[]

  # Sort by time first
  var sortedTweets = tweets
  sortedTweets.sort(proc(a, b: Tweet): int = cmp(a.time, b.time))

  for tweet in sortedTweets:
    let tweetDate = tweet.time.format("yyyy-MM-dd")
    if tweetDate != currentDate:
      if currentTweets.len > 0:
        byDay.add (currentDate, currentTweets)
      currentDate = tweetDate
      currentTweets = @[tweet]
    else:
      currentTweets.add tweet

  # Don't forget the last batch
  if currentTweets.len > 0:
    byDay.add (currentDate, currentTweets)

  return byDay

proc scrapeWindow(username: string; startDate, endDate: DateTime): Future[tuple[tweets: seq[Tweet], truncated: bool]] {.async.} =
  ## Scrape all tweets from a user in a date range
  ## Returns (tweets, truncated) where truncated=true if we hit the limit
  var searchQuery = Query(
    kind: QueryKind.tweets,
    text: "",
    fromUser: @[username],
    since: startDate.format("yyyy-MM-dd"),
    until: (endDate + 1.days).format("yyyy-MM-dd")  # until is exclusive
  )

  var
    cursor = ""
    tweets: seq[Tweet] = @[]
    truncated = false

  while tweets.len < maxResultsPerWindow:
    let results = await getGraphTweetSearch(searchQuery, cursor)

    if results.content.len == 0:
      break

    for batch in results.content:
      for tweet in batch:
        tweets.add tweet
        if tweets.len >= maxResultsPerWindow:
          truncated = true
          break
      if tweets.len >= maxResultsPerWindow:
        break

    if results.bottom.len == 0:
      break

    cursor = results.bottom
    await sleepAsync(delayBetweenPages)

  return (tweets, truncated)

proc scrapeDay(username, date: string): Future[seq[Tweet]] {.async.} =
  ## Scrape all tweets from a user on a specific day (convenience wrapper)
  let dateTime = parse(date, "yyyy-MM-dd")
  let (tweets, _) = await scrapeWindow(username, dateTime, dateTime)
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
  ## Scrape a user's timeline using adaptive window sizing
  ## skipDays: list of dates to skip (already processed in this run)
  let today = now().utc
  var
    totalTweets = 0
    daysProcessed = 0
    daysWithTweets = 0
    lastTodayRefresh = epochTime()

  # Calculate EMA and initial window size
  var ema = calculateEma(outputDir)
  var windowDays = calculateWindowDays(ema)

  # If end date is today or in future, we'll keep refreshing "today"
  let trackingToday = endDate >= today

  let direction = if backwards: "backwards" else: "forwards"
  if backwards:
    echo fmt"Scraping @{username} from {endDate.format(""yyyy-MM-dd"")} backwards to {startDate.format(""yyyy-MM-dd"")}"
  else:
    echo fmt"Scraping @{username} from {startDate.format(""yyyy-MM-dd"")} forwards to {endDate.format(""yyyy-MM-dd"")}"

  echo fmt"EMA: {ema:.1f} tweets/day, window size: {windowDays} days"
  if trackingToday and backwards:
    echo fmt"(Will refresh today's tweets every {refreshTodayInterval div 3600} hours)"
  echo fmt"Output directory: {outputDir}"
  echo ""

  log fmt"START {direction}: @{username}, EMA={ema:.1f}, window={windowDays} days"
  showSessionHealth()

  var currentEnd = if backwards: endDate else: startDate
  var currentStart: DateTime

  while (backwards and currentEnd >= startDate) or (not backwards and currentEnd <= endDate):
    # Calculate window boundaries
    if backwards:
      currentStart = currentEnd - (windowDays - 1).days
      if currentStart < startDate:
        currentStart = startDate
    else:
      currentStart = currentEnd
      currentEnd = currentStart + (windowDays - 1).days
      if currentEnd > endDate:
        currentEnd = endDate

    let windowStartStr = currentStart.format("yyyy-MM-dd")
    let windowEndStr = currentEnd.format("yyyy-MM-dd")
    let todayStr = now().utc.format("yyyy-MM-dd")

    # Check if entire window is in skipDays (unlikely but handle it)
    var allSkipped = true
    var checkDate = currentStart
    while checkDate <= currentEnd:
      if checkDate.format("yyyy-MM-dd") notin skipDays:
        allSkipped = false
        break
      checkDate = checkDate + 1.days

    if allSkipped:
      if backwards:
        currentEnd = currentStart - 1.days
      else:
        currentEnd = currentEnd + 1.days
      continue

    try:
      let windowLabel = if windowDays == 1: windowStartStr
                        else: fmt"{windowStartStr} to {windowEndStr}"

      var (tweets, truncated) = await scrapeWindow(username, currentStart, currentEnd)

      if truncated:
        # Hit the limit - halve window and retry
        windowDays = max(minWindowDays, windowDays div 2)
        echo fmt"{windowLabel}: TRUNCATED at {tweets.len} tweets, reducing window to {windowDays} days"
        log fmt"TRUNCATED: {windowLabel}, new window={windowDays}"
        # Update EMA estimate (this window had high volume)
        let actualDays = (currentEnd - currentStart).inDays.int + 1
        let impliedDaily = tweets.len.float / actualDays.float
        ema = max(ema, impliedDaily)  # Adjust EMA upward
        continue  # Retry with smaller window

      # Split tweets by day and write CSVs
      let byDay = splitTweetsByDay(tweets)
      var windowTweets = 0
      var windowDaysWithTweets = 0

      for (dateStr, dayTweets) in byDay:
        if dateStr in skipDays:
          continue
        var mutableTweets = dayTweets
        let count = writeDayCsv(outputDir, dateStr, mutableTweets)
        if count > 0:
          windowTweets += count
          inc windowDaysWithTweets
          inc daysWithTweets

        # Track incomplete days
        if dateStr == todayStr:
          markDayIncomplete(outputDir, dateStr)
        else:
          markDayComplete(outputDir, dateStr)

      totalTweets += windowTweets
      let actualDays = (currentEnd - currentStart).inDays.int + 1
      daysProcessed += actualDays

      if windowTweets > 0:
        echo fmt"{windowLabel}: {windowTweets} tweets across {windowDaysWithTweets} days (total: {totalTweets})"
      else:
        echo fmt"{windowLabel}: 0 tweets (total: {totalTweets})"

      # Update EMA with actual data
      if actualDays > 0 and windowTweets > 0:
        let actualDaily = windowTweets.float / actualDays.float
        ema = emaAlpha * actualDaily + (1.0 - emaAlpha) * ema
        windowDays = calculateWindowDays(ema)

    except RateLimitError:
      echo fmt"Rate limited! Waiting 60s..."
      showSessionHealth()
      log fmt"RATE_LIMIT: waiting 60s"
      await sleepAsync(60000)
      continue
    except NoSessionsError:
      echo fmt"No sessions available. Waiting 15 min..."
      log fmt"NO_SESSIONS: waiting 15 min"
      await sleepAsync(noSessionsRetryDelay)
      continue
    except Exception as e:
      echo fmt"Error: {e.msg}"
      log fmt"ERROR: {e.msg}"
      # Move past this window on error
      let actualDays = (currentEnd - currentStart).inDays.int + 1
      daysProcessed += actualDays

    # Move to next window
    if backwards:
      currentEnd = currentStart - 1.days
    else:
      currentEnd = currentEnd + 1.days

    # Check if we should refresh "today" (only when going backwards)
    if trackingToday and backwards:
      let elapsed = epochTime() - lastTodayRefresh
      if elapsed >= refreshTodayInterval.float:
        echo fmt"[Refreshing today: {todayStr}]"
        try:
          var todayTweets = await scrapeDay(username, todayStr)
          let count = writeDayCsv(outputDir, todayStr, todayTweets, merge=true)
          if count > 0:
            echo fmt"  -> {count} tweets today"
        except:
          echo fmt"  -> Failed to refresh today"
        lastTodayRefresh = epochTime()

    await sleepAsync(delayBetweenWindows)

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
        await sleepAsync(delayBetweenWindows)
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
