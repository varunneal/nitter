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
  noSessionsRetryDelay = 5 * 60 * 1000  # wait 5 min if no sessions, then retry (ms)

var logFile: File

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

proc findEarliestScrapedDate(outputDir: string): Option[DateTime] =
  ## Scan output directory for existing CSVs and find the earliest date (for backwards scraping)
  if not dirExists(outputDir):
    return none(DateTime)

  var earliestDate: Option[DateTime] = none(DateTime)

  for file in walkFiles(outputDir / "*.csv"):
    let filename = extractFilename(file)
    if filename.len >= 10:  # "YYYY-MM-DD.csv"
      try:
        let dateStr = filename[0..9]
        let date = parse(dateStr, "yyyy-MM-dd")
        if earliestDate.isNone or date < earliestDate.get:
          earliestDate = some(date)
      except:
        discard  # Skip files that don't match date pattern

  return earliestDate

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

proc writeDayCsv(outputDir, dateStr: string; tweets: var seq[Tweet]): int =
  ## Write tweets to a daily CSV file, returns count written
  if tweets.len == 0:
    return 0

  # Sort tweets by time (oldest first)
  tweets.sort(proc(a, b: Tweet): int = cmp(a.time, b.time))

  let csvPath = outputDir / fmt"{dateStr}.csv"
  var csvFile = open(csvPath, fmWrite)
  defer: csvFile.close()

  csvFile.writeLine(getCsvHeader())
  for tweet in tweets:
    csvFile.writeLine(tweetToCsvRow(tweet))

  return tweets.len

proc scrapeTimeline(username: string; startDate, endDate: DateTime; outputDir: string) {.async.} =
  ## Scrape a user's timeline day by day (backwards from endDate), outputting daily CSV files
  let today = now().utc
  var
    currentDate = endDate  # Start from end, go backwards
    totalTweets = 0
    daysProcessed = 0
    daysWithTweets = 0
    lastTodayRefresh = epochTime()
    currentMonth = endDate.format("yyyy-MM")

  # If end date is today or in future, we'll keep refreshing "today"
  let trackingToday = endDate >= today

  echo fmt"Scraping @{username} from {endDate.format(""yyyy-MM-dd"")} backwards to {startDate.format(""yyyy-MM-dd"")}"
  if trackingToday:
    echo fmt"(Will refresh today's tweets every {refreshTodayInterval div 3600} hours)"
  echo fmt"Output directory: {outputDir}"
  echo ""

  log fmt"START: @{username} from {endDate.format(""yyyy-MM-dd"")} to {startDate.format(""yyyy-MM-dd"")}"
  showSessionHealth()

  while currentDate >= startDate:
    let dateStr = currentDate.format("yyyy-MM-dd")
    let isToday = dateStr == now().utc.format("yyyy-MM-dd")

    # Check for month milestone (going backwards)
    let thisMonth = currentDate.format("yyyy-MM")
    if thisMonth != currentMonth:
      log fmt"MONTH: reached {thisMonth} (total: {totalTweets} tweets)"
      currentMonth = thisMonth

    try:
      var tweets = await scrapeDay(username, dateStr)
      let count = writeDayCsv(outputDir, dateStr, tweets)

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
      echo fmt"{dateStr}: No sessions available (API rate limited). Waiting 5 min then retry..."
      showSessionHealth()
      log fmt"NO_SESSIONS: {dateStr} - waiting 5 min"
      await sleepAsync(noSessionsRetryDelay)
      # Retry the same day - if still limited, we'll wait another 5 min
      continue
    except Exception as e:
      echo fmt"{dateStr}: Error - {e.msg}"
      log fmt"ERROR: {dateStr} - {e.msg}"
      inc daysProcessed

    currentDate = currentDate - 1.days  # Go backwards

    # Check if we should refresh "today"
    if trackingToday and not isToday:
      let elapsed = epochTime() - lastTodayRefresh
      if elapsed >= refreshTodayInterval.float:
        let todayStr = now().utc.format("yyyy-MM-dd")
        echo fmt"[Refreshing today: {todayStr}]"
        try:
          var todayTweets = await scrapeDay(username, todayStr)
          let count = writeDayCsv(outputDir, todayStr, todayTweets)
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

  # Check for existing progress and auto-resume (we scrape backwards)
  var effectiveEndDate = endDate
  let earliestScraped = findEarliestScrapedDate(outputDir)
  if earliestScraped.isSome:
    let resumeDate = earliestScraped.get
    if resumeDate > requestedStartDate:
      effectiveEndDate = resumeDate  # Resume from earliest scraped day (re-scrape it)
      echo fmt"Found existing data down to {resumeDate.format(""yyyy-MM-dd"")}"
      echo fmt"Resuming backwards from {effectiveEndDate.format(""yyyy-MM-dd"")} (re-scraping that day)"
      echo ""

  # Load config
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

  echo ""
  await scrapeTimeline(username, requestedStartDate, effectiveEndDate, outputDir)

when isMainModule:
  waitFor main()
