# SPDX-License-Identifier: AGPL-3.0-only
# Daemon scraper - continuously scrapes accounts in round-robin fashion
# Designed to run on a VM indefinitely

import std/[asyncdispatch, os, strutils, strformat, options, times, algorithm, json, tables, sequtils]
import types, config, auth, api, query

const
  maxResultsPerWindow = 1000
  targetTweetsPerWindow = 750
  delayBetweenPages = 3000      # 3s between pagination
  delayBetweenWindows = 5000    # 5s between windows
  delayBetweenAccounts = 2000   # 2s between switching accounts
  maxWindowDays = 60
  minWindowDays = 1
  defaultEma = 10.0
  emaAlpha = 0.3
  outputBaseDir = "output"
  accountsFile = "accounts-starts.txt"
  todayRefreshInterval = 30 * 60  # Refresh "today" every 30 min per account
  noSessionsRetryDelay = 15 * 60 * 1000  # 15 min wait

type
  AccountState = object
    username: string
    startDate: DateTime
    currentDate: DateTime      # Where we are in historical scraping
    lastTodayRefresh: float    # epochTime of last today refresh
    ema: float
    windowDays: int
    historicalDone: bool       # True if we've reached startDate

var logFile: File

proc log(msg: string) =
  let timestamp = now().utc.format("yyyy-MM-dd HH:mm:ss")
  let line = fmt"[{timestamp}] {msg}"
  echo line
  if logFile != nil:
    logFile.writeLine(line)
    logFile.flushFile()

proc escapeCsv(s: string): string =
  result = s
  if result.contains('"') or result.contains(',') or result.contains('\n') or result.contains('\r'):
    result = result.replace("\"", "\"\"")
    result = "\"" & result & "\""

proc ensureHttps(url: string): string =
  if url.startsWith("https://") or url.startsWith("http://"):
    return url
  elif url.startsWith("//"):
    return "https:" & url
  else:
    return "https://" & url

proc getMediaUrls(tweet: Tweet): string =
  var urls: seq[string] = @[]
  for photo in tweet.photos:
    urls.add fmt"https://pbs.twimg.com/{photo}"
  if tweet.video.isSome:
    let video = tweet.video.get
    for v in video.variants:
      if v.url.len > 0 and v.contentType == mp4:
        urls.add v.url.ensureHttps
        break
  if tweet.gif.isSome:
    urls.add tweet.gif.get.url.ensureHttps
  return urls.join(";")

proc tweetToCsvRow(tweet: Tweet): string =
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
  result = @[]
  if not fileExists(csvPath):
    return
  var first = true
  for line in lines(csvPath):
    if first:
      first = false
      continue
    if line.len == 0:
      continue
    let commaPos = line.find(',')
    if commaPos > 0:
      try:
        result.add parseBiggestInt(line[0..<commaPos])
      except:
        discard

proc loadExistingCsvLines(csvPath: string): seq[string] =
  result = @[]
  if not fileExists(csvPath):
    return
  var first = true
  for line in lines(csvPath):
    if first:
      first = false
      continue
    if line.len > 0:
      result.add line

proc writeDayCsv(outputDir, dateStr: string; tweets: var seq[Tweet]; merge = false): int =
  let csvPath = outputDir / fmt"{dateStr}.csv"
  var existingLines: seq[string] = @[]
  var existingIds: seq[int64] = @[]

  if merge and fileExists(csvPath):
    existingIds = loadExistingTweetIds(csvPath)
    existingLines = loadExistingCsvLines(csvPath)

  if tweets.len == 0 and existingLines.len == 0:
    return 0

  tweets.sort(proc(a, b: Tweet): int = cmp(a.time, b.time))

  var newIds: seq[int64] = @[]
  for tweet in tweets:
    newIds.add tweet.id

  var csvFile = open(csvPath, fmWrite)
  defer: csvFile.close()

  csvFile.writeLine(getCsvHeader())
  for tweet in tweets:
    csvFile.writeLine(tweetToCsvRow(tweet))

  var preservedCount = 0
  if merge:
    for i, oldId in existingIds:
      if oldId notin newIds:
        csvFile.writeLine(existingLines[i])
        inc preservedCount

  return tweets.len + preservedCount

proc splitTweetsByDay(tweets: seq[Tweet]): seq[tuple[date: string, tweets: seq[Tweet]]] =
  var byDay: seq[tuple[date: string, tweets: seq[Tweet]]] = @[]
  var currentDate = ""
  var currentTweets: seq[Tweet] = @[]

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

  if currentTweets.len > 0:
    byDay.add (currentDate, currentTweets)

  return byDay

proc scrapeWindow(username: string; startDate, endDate: DateTime): Future[tuple[tweets: seq[Tweet], truncated: bool]] {.async.} =
  var searchQuery = Query(
    kind: QueryKind.tweets,
    text: "",
    fromUser: @[username],
    since: startDate.format("yyyy-MM-dd"),
    until: (endDate + 1.days).format("yyyy-MM-dd")
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

proc calculateEma(outputDir: string): float =
  if not dirExists(outputDir):
    return defaultEma

  var dayCounts: seq[tuple[date: DateTime, count: int]] = @[]

  for file in walkFiles(outputDir / "*.csv"):
    let filename = extractFilename(file)
    if filename.len >= 10:
      try:
        let dateStr = filename[0..9]
        let date = parse(dateStr, "yyyy-MM-dd")
        var lineCount = 0
        for _ in lines(file):
          inc lineCount
        dayCounts.add (date, max(0, lineCount - 1))
      except:
        discard

  if dayCounts.len == 0:
    return defaultEma

  dayCounts.sort(proc(a, b: tuple[date: DateTime, count: int]): int = cmp(a.date, b.date))

  var ema = dayCounts[0].count.float
  for i in 1..<dayCounts.len:
    ema = emaAlpha * dayCounts[i].count.float + (1.0 - emaAlpha) * ema

  return max(1.0, ema)

proc findEarliestScraped(outputDir: string): Option[DateTime] =
  if not dirExists(outputDir):
    return none(DateTime)

  var earliest: Option[DateTime] = none(DateTime)
  for file in walkFiles(outputDir / "*.csv"):
    let filename = extractFilename(file)
    if filename.len >= 10:
      try:
        let date = parse(filename[0..9], "yyyy-MM-dd")
        if earliest.isNone or date < earliest.get:
          earliest = some(date)
      except:
        discard
  return earliest

proc loadAccounts(path: string): seq[tuple[username: string, startDate: DateTime]] =
  result = @[]
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let parts = trimmed.splitWhitespace()
    if parts.len >= 2:
      var username = parts[0]
      if username.startsWith("@"):
        username = username[1..^1]
      try:
        let startDate = parse(parts[1], "yyyy-MM-dd")
        result.add (username, startDate)
      except:
        log fmt"Invalid date for {username}: {parts[1]}"

proc initAccountState(username: string; startDate: DateTime; outputDir: string): AccountState =
  result.username = username
  result.startDate = startDate
  result.ema = calculateEma(outputDir)
  result.windowDays = max(minWindowDays, min(maxWindowDays, int(targetTweetsPerWindow / result.ema)))
  result.lastTodayRefresh = 0
  result.historicalDone = false

  # Find where to resume from
  let earliest = findEarliestScraped(outputDir)
  if earliest.isSome:
    result.currentDate = earliest.get - 1.days
    if result.currentDate < startDate:
      result.historicalDone = true
      result.currentDate = startDate
  else:
    result.currentDate = now().utc - 1.days  # Start from yesterday

type
  RefreshResult = object
    count: int

  HistoricalResult = object
    tweets: int
    done: bool
    truncated: bool
    newEma: float
    newWindowDays: int
    newCurrentDate: DateTime

proc refreshToday(username: string; outputDir: string): Future[RefreshResult] {.async.} =
  let todayStr = now().utc.format("yyyy-MM-dd")
  let todayDt = parse(todayStr, "yyyy-MM-dd")

  let (tweets, _) = await scrapeWindow(username, todayDt, todayDt)
  var mutableTweets = tweets
  let count = writeDayCsv(outputDir, todayStr, mutableTweets, merge=true)

  return RefreshResult(count: count)

proc scrapeHistoricalWindow(state: AccountState; outputDir: string): Future[HistoricalResult] {.async.} =
  if state.historicalDone:
    return HistoricalResult(tweets: 0, done: true, truncated: false,
                            newEma: state.ema, newWindowDays: state.windowDays,
                            newCurrentDate: state.currentDate)

  let windowEnd = state.currentDate
  var windowStart = windowEnd - (state.windowDays - 1).days
  if windowStart < state.startDate:
    windowStart = state.startDate

  let (tweets, truncated) = await scrapeWindow(state.username, windowStart, windowEnd)

  if truncated:
    let newWindowDays = max(minWindowDays, state.windowDays div 2)
    let actualDays = (windowEnd - windowStart).inDays.int + 1
    let newEma = max(state.ema, tweets.len.float / actualDays.float)
    return HistoricalResult(tweets: 0, done: false, truncated: true,
                            newEma: newEma, newWindowDays: newWindowDays,
                            newCurrentDate: state.currentDate)

  # Write CSVs
  let byDay = splitTweetsByDay(tweets)
  var totalWritten = 0
  for (dateStr, dayTweets) in byDay:
    var mutableTweets = dayTweets
    totalWritten += writeDayCsv(outputDir, dateStr, mutableTweets)

  # Calculate new EMA
  let actualDays = (windowEnd - windowStart).inDays.int + 1
  var newEma = state.ema
  var newWindowDays = state.windowDays
  if actualDays > 0 and tweets.len > 0:
    let actualDaily = tweets.len.float / actualDays.float
    newEma = emaAlpha * actualDaily + (1.0 - emaAlpha) * state.ema
    newWindowDays = max(minWindowDays, min(maxWindowDays, int(targetTweetsPerWindow / newEma)))

  # Calculate next position
  let newCurrentDate = windowStart - 1.days
  let done = newCurrentDate < state.startDate

  return HistoricalResult(tweets: totalWritten, done: done, truncated: false,
                          newEma: newEma, newWindowDays: newWindowDays,
                          newCurrentDate: newCurrentDate)

proc main() {.async.} =
  echo "=== Nitter Daemon Scraper ==="
  echo fmt"Reading accounts from: {accountsFile}"
  echo ""

  let rawAccounts = loadAccounts(accountsFile)
  if rawAccounts.len == 0:
    echo fmt"Error: No accounts found in {accountsFile}"
    echo "Format: username YYYY-MM-DD (one per line)"
    quit(1)

  # Load config
  let configPath = if fileExists("nitter.conf"): "nitter.conf"
                   elif fileExists("nitter.example.conf"): "nitter.example.conf"
                   else: ""
  if configPath.len == 0:
    echo "Error: No config file found"
    quit(1)

  if not fileExists("sessions.jsonl"):
    echo "Error: sessions.jsonl not found"
    quit(1)

  let (cfg, _) = getConfig(configPath)
  initSessionPool(cfg, "sessions.jsonl")

  # Open log file
  createDir(outputBaseDir)
  logFile = open(outputBaseDir / "daemon.log", fmAppend)
  defer: logFile.close()

  # Initialize account states
  var accounts: seq[AccountState] = @[]
  for (username, startDate) in rawAccounts:
    let outputDir = outputBaseDir / username
    createDir(outputDir)
    accounts.add initAccountState(username, startDate, outputDir)
    log fmt"Loaded @{username}: start={startDate.format(""yyyy-MM-dd"")}, ema={accounts[^1].ema:.1f}, window={accounts[^1].windowDays}d"

  echo fmt"Loaded {accounts.len} accounts"
  echo ""

  log "=== Daemon started ==="

  var currentIdx = 0
  var totalTweets = 0
  var iterations = 0

  while true:
    let outputDir = outputBaseDir / accounts[currentIdx].username
    let now_time = epochTime()

    try:
      # Check if we should refresh today
      let shouldRefreshToday = (now_time - accounts[currentIdx].lastTodayRefresh) >= todayRefreshInterval.float

      if shouldRefreshToday:
        let res = await refreshToday(accounts[currentIdx].username, outputDir)
        accounts[currentIdx].lastTodayRefresh = epochTime()
        if res.count > 0:
          log fmt"@{accounts[currentIdx].username} today: {res.count} tweets"
          totalTweets += res.count
        await sleepAsync(delayBetweenWindows)

      # Do one historical window if not done
      if not accounts[currentIdx].historicalDone:
        let windowLabel = fmt"{accounts[currentIdx].currentDate.format(""yyyy-MM-dd"")} (window={accounts[currentIdx].windowDays}d)"
        let res = await scrapeHistoricalWindow(accounts[currentIdx], outputDir)

        # Update state from result
        accounts[currentIdx].ema = res.newEma
        accounts[currentIdx].windowDays = res.newWindowDays
        accounts[currentIdx].currentDate = res.newCurrentDate
        accounts[currentIdx].historicalDone = res.done

        if res.truncated:
          log fmt"@{accounts[currentIdx].username} {windowLabel}: TRUNCATED, reducing window to {res.newWindowDays}d"
          continue  # Retry immediately with smaller window

        if res.tweets > 0:
          log fmt"@{accounts[currentIdx].username} {windowLabel}: {res.tweets} tweets"
          totalTweets += res.tweets
        if res.done:
          log fmt"@{accounts[currentIdx].username} historical scraping complete!"
        await sleepAsync(delayBetweenWindows)

    except RateLimitError:
      log fmt"Rate limited on @{accounts[currentIdx].username}, waiting 60s..."
      await sleepAsync(60000)
      continue
    except NoSessionsError:
      log "No sessions available, waiting 15 min..."
      await sleepAsync(noSessionsRetryDelay)
      continue
    except Exception as e:
      log fmt"Error on @{accounts[currentIdx].username}: {e.msg}"

    # Move to next account (round-robin)
    currentIdx = (currentIdx + 1) mod accounts.len
    inc iterations

    # Status update every full round
    if currentIdx == 0:
      let allDone = accounts.allIt(it.historicalDone)
      if allDone:
        log fmt"All historical done. Total tweets: {totalTweets}. Refreshing today only."
      else:
        let remaining = accounts.filterIt(not it.historicalDone).len
        log fmt"Round complete. {remaining}/{accounts.len} accounts still have historical work. Total: {totalTweets}"

    await sleepAsync(delayBetweenAccounts)

when isMainModule:
  waitFor main()
