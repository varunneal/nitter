# SPDX-License-Identifier: AGPL-3.0-only
# Daily scraper - run once per day to collect tweets from a list of accounts

import std/[asyncdispatch, os, strutils, strformat, options, times, algorithm, json]
import types, config, auth, api

const
  delayBetweenPages = 3000    # ms between pagination requests
  delayBetweenAccounts = 5000 # ms between accounts
  maxResultsPerDay = 1000
  outputBaseDir = "output"
  accountsFile = "accounts.txt"

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

proc scrapeDay(username, date: string): Future[seq[Tweet]] {.async.} =
  var searchQuery = Query(
    kind: QueryKind.tweets,
    text: "",
    fromUser: @[username],
    since: date,
    until: (parse(date, "yyyy-MM-dd") + 1.days).format("yyyy-MM-dd")
  )

  var
    cursor = ""
    tweets: seq[Tweet] = @[]

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
    await sleepAsync(delayBetweenPages)

  return tweets

proc writeDayCsv(outputDir, dateStr: string; tweets: var seq[Tweet]; merge = true): int =
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

proc loadAccounts(path: string): seq[string] =
  result = @[]
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len > 0 and not trimmed.startsWith("#"):
      # Remove @ prefix if present
      if trimmed.startsWith("@"):
        result.add trimmed[1..^1]
      else:
        result.add trimmed

proc main() {.async.} =
  let args = commandLineParams()

  # Determine which date to scrape
  # Default: yesterday (safest, day is complete)
  # Can pass "today" or a specific date
  let targetDate = if args.len > 0:
                     if args[0].toLowerAscii == "today":
                       now().utc.format("yyyy-MM-dd")
                     elif args[0].toLowerAscii == "yesterday":
                       (now().utc - 1.days).format("yyyy-MM-dd")
                     else:
                       args[0]  # Assume YYYY-MM-DD format
                   else:
                     (now().utc - 1.days).format("yyyy-MM-dd")

  echo "=== Daily Tweet Scraper ==="
  echo fmt"Target date: {targetDate}"
  echo ""

  # Load accounts
  let accounts = loadAccounts(accountsFile)
  if accounts.len == 0:
    echo fmt"Error: No accounts found in {accountsFile}"
    echo "Create accounts.txt with one username per line"
    quit(1)

  echo fmt"Accounts to scrape: {accounts.len}"
  for acc in accounts:
    echo fmt"  - @{acc}"
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

  # Scrape each account
  var totalTweets = 0
  var successCount = 0
  var failCount = 0

  for i, username in accounts:
    let outputDir = outputBaseDir / username
    createDir(outputDir)

    echo fmt"[{i+1}/{accounts.len}] @{username}..."

    try:
      var tweets = await scrapeDay(username, targetDate)
      let count = writeDayCsv(outputDir, targetDate, tweets)

      if count > 0:
        echo fmt"  {count} tweets"
        totalTweets += count
      else:
        echo "  0 tweets"

      inc successCount
    except RateLimitError:
      echo "  Rate limited! Waiting 60s..."
      await sleepAsync(60000)
      # Retry once
      try:
        var tweets = await scrapeDay(username, targetDate)
        let count = writeDayCsv(outputDir, targetDate, tweets)
        echo fmt"  {count} tweets (after retry)"
        totalTweets += count
        inc successCount
      except:
        echo "  Failed after retry"
        inc failCount
    except NoSessionsError:
      echo "  No sessions available, skipping..."
      inc failCount
    except Exception as e:
      echo fmt"  Error: {e.msg}"
      inc failCount

    if i < accounts.len - 1:
      await sleepAsync(delayBetweenAccounts)

  echo ""
  echo "=== Summary ==="
  echo fmt"Date: {targetDate}"
  echo fmt"Accounts: {successCount} succeeded, {failCount} failed"
  echo fmt"Total tweets: {totalTweets}"

when isMainModule:
  echo ""
  echo "Usage: scrape_daily [date]"
  echo "  date: 'yesterday' (default), 'today', or YYYY-MM-DD"
  echo ""
  echo fmt"Reads accounts from: {accountsFile}"
  echo fmt"Output: {outputBaseDir}/<username>/<date>.csv"
  echo ""

  waitFor main()
