# SPDX-License-Identifier: AGPL-3.0-only
# Simple script to search tweets from a user with date filters

import std/[asyncdispatch, os, strutils, strformat, options, times]
import types, config, auth, api, query, apiutils

const
  defaultUser = "elonmusk"
  defaultSearchTerm = "Tesla"
  defaultSince = "2024-10-01"
  defaultUntil = "2024-10-31"

proc printTweet(tweet: Tweet) =
  let timeStr = tweet.time.format("yyyy-MM-dd HH:mm:ss")
  let tweetUrl = fmt"https://x.com/{tweet.user.username}/status/{tweet.id}"
  echo "----------------------------------------"
  echo fmt"@{tweet.user.username} - {timeStr}"
  echo tweetUrl
  echo ""
  echo tweet.text
  echo ""
  echo fmt"Replies: {tweet.stats.replies} | Retweets: {tweet.stats.retweets} | Likes: {tweet.stats.likes} | Views: {tweet.stats.views}"

  if tweet.photos.len > 0:
    echo fmt"Photos ({tweet.photos.len}):"
    for photo in tweet.photos:
      echo fmt"  https://pbs.twimg.com/{photo}"
  if tweet.video.isSome:
    let video = tweet.video.get
    echo "Video:"
    echo fmt"  Thumbnail: https://pbs.twimg.com/{video.thumb}"
    for variant in video.variants:
      if variant.url.len > 0:
        echo fmt"  {variant.contentType} ({variant.bitrate}): {variant.url}"
  if tweet.gif.isSome:
    let gif = tweet.gif.get
    echo fmt"GIF: {gif.url}"
  if tweet.quote.isSome:
    echo "Quote tweet"

proc search(username, searchTerm, since, until: string; maxResults: int = 50) {.async.} =
  # Build search query
  # The query format is: "searchTerm from:username since:YYYY-MM-DD until:YYYY-MM-DD"
  var searchQuery = Query(
    kind: QueryKind.tweets,
    text: searchTerm,
    fromUser: @[username],
    since: since,
    until: until
  )

  echo fmt"Searching for '{searchTerm}' from @{username}"
  echo fmt"Date range: {since} to {until}"
  echo ""

  var
    cursor = ""
    totalTweets = 0
    pageNum = 1

  while totalTweets < maxResults:
    echo fmt"Fetching page {pageNum}..."

    let results = await getGraphTweetSearch(searchQuery, cursor)

    if results.content.len == 0:
      echo "No more results"
      break

    for tweets in results.content:
      for tweet in tweets:
        printTweet(tweet)
        inc totalTweets

        if totalTweets >= maxResults:
          break
      if totalTweets >= maxResults:
        break

    # Check for more pages
    if results.bottom.len == 0:
      echo "Reached end of results"
      break

    cursor = results.bottom
    inc pageNum

    # Small delay to be respectful of rate limits
    await sleepAsync(500)

  echo ""
  echo fmt"Total tweets found: {totalTweets}"

proc main() {.async.} =
  # Parse command line arguments
  let args = commandLineParams()

  let searchTerm = if args.len > 0: args[0] else: defaultSearchTerm
  let username = if args.len > 1: args[1] else: defaultUser
  let since = if args.len > 2: args[2] else: defaultSince
  let until = if args.len > 3: args[3] else: defaultUntil
  let maxResults = if args.len > 4: parseInt(args[4]) else: 50

  echo "=== Nitter Search Script ==="
  echo ""

  # Check for config file
  let configPath = if fileExists("nitter.conf"): "nitter.conf"
                   elif fileExists("nitter.example.conf"): "nitter.example.conf"
                   else: ""

  if configPath.len == 0:
    echo "Error: No config file found (nitter.conf or nitter.example.conf)"
    quit(1)

  echo fmt"Using config: {configPath}"

  # Check for sessions file
  let sessionsPath = "sessions.jsonl"
  if not fileExists(sessionsPath):
    echo fmt"Error: Sessions file not found: {sessionsPath}"
    echo "Please create sessions.jsonl with your authentication credentials"
    quit(1)

  # Load configuration
  let (cfg, _) = getConfig(configPath)

  # Initialize session pool
  echo fmt"Loading sessions from: {sessionsPath}"
  initSessionPool(cfg, sessionsPath)

  echo ""

  # Perform search
  try:
    await search(username, searchTerm, since, until, maxResults)
  except RateLimitError:
    echo "Error: Rate limited. Try again later or add more sessions."
  except NoSessionsError:
    echo "Error: No valid sessions available. Check your sessions.jsonl file."
  except Exception as e:
    echo fmt"Error: {e.msg}"

when isMainModule:
  echo ""
  echo "Usage: main [searchTerm] [username] [since] [until] [maxResults]"
  echo fmt"Defaults: searchTerm={defaultSearchTerm}, username={defaultUser}, since={defaultSince}, until={defaultUntil}, maxResults=50"
  echo ""

  waitFor main()
