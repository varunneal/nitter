# Nitter API Documentation

This document provides a lightweight reference for the exposed functions in the nitter codebase, useful for writing custom scripts.

---

## Scripts

### Search Tweets (`src/main.nim`)

Search for tweets from a user with filters.

```bash
nim c -d:ssl src/main.nim
./src/main [searchTerm] [username] [since] [until] [maxResults]
```

**Example:**
```bash
./src/main "SpaceX" "elonmusk" "2024-10-01" "2024-10-31" 20
```

### Scrape Timeline (`src/scrape_timeline.nim`)

Scrape a user's full timeline by searching day-by-day. Outputs CSV files organized by date.

```bash
nim c -d:ssl src/scrape_timeline.nim
./src/scrape_timeline <username> <start_date> <end_date>
```

**Example:**
```bash
./src/scrape_timeline coldhealing 2024-01-01 2024-12-31
```

**Output structure:**
```
output/
└── <username>/
    ├── 2024-01-01.csv
    ├── 2024-01-02.csv
    └── ...
```

**CSV columns:** `id, url, time, text, replies, retweets, likes, views, media, has_quote`

**Features:**
- Day-by-day search bypasses Twitter's timeline pagination limits
- Resumable: just change start_date to continue where you left off
- Auto-retries on rate limit (waits 60s)
- Tweets sorted by time within each day

---

## Table of Contents

1. [Core Types](#core-types)
2. [Session/Authentication](#sessionauthentication)
3. [Configuration](#configuration)
4. [API Functions](#api-functions)
5. [Query Building](#query-building)
6. [Parsing Functions](#parsing-functions)
7. [Utility Functions](#utility-functions)

---

## Core Types

Defined in `src/types.nim`:

### User
```nim
User* = object
  id*: string
  username*: string
  fullname*: string
  location*: string
  website*: string
  bio*: string
  userPic*: string
  banner*: string
  pinnedTweet*: int64
  following*: int
  followers*: int
  tweets*: int
  likes*: int
  media*: int
  verifiedType*: VerifiedType  # none, blue, business, government
  protected*: bool
  suspended*: bool
  joinDate*: DateTime
```

### Tweet
```nim
Tweet* = ref object
  id*: int64
  threadId*: int64
  replyId*: int64
  user*: User
  text*: string
  time*: DateTime
  reply*: seq[string]
  pinned*: bool
  hasThread*: bool
  available*: bool
  tombstone*: string
  location*: string
  stats*: TweetStats
  retweet*: Option[Tweet]
  attribution*: Option[User]
  mediaTags*: seq[User]
  quote*: Option[Tweet]
  card*: Option[Card]
  poll*: Option[Poll]
  gif*: Option[Gif]
  video*: Option[Video]
  photos*: seq[string]
```

### TweetStats
```nim
TweetStats* = object
  replies*: int
  retweets*: int
  likes*: int
  views*: int
```

### Timeline / Result
```nim
Result*[T] = object
  content*: seq[T]
  top*, bottom*: string    # Cursors for pagination
  beginning*: bool
  query*: Query

Timeline* = Result[Tweets]  # Tweets = seq[Tweet]
```

### Profile
```nim
Profile* = object
  user*: User
  photoRail*: PhotoRail
  pinned*: Option[Tweet]
  tweets*: Timeline
```

### Conversation
```nim
Conversation* = ref object
  tweet*: Tweet
  before*: Chain           # Tweets before main tweet in thread
  after*: Chain            # Tweets after main tweet (self-thread)
  replies*: Result[Chain]  # Reply threads
```

### Chain
```nim
Chain* = object
  content*: Tweets
  hasMore*: bool
  cursor*: string
```

### List
```nim
List* = object
  id*: string
  name*: string
  userId*: string
  username*: string
  description*: string
  members*: int
  banner*: string
```

### Query
```nim
Query* = object
  kind*: QueryKind      # posts, replies, media, users, tweets, userList
  text*: string
  filters*: seq[string]
  includes*: seq[string]
  excludes*: seq[string]
  fromUser*: seq[string]
  since*: string        # Date string "YYYY-MM-DD"
  until*: string        # Date string "YYYY-MM-DD"
  minLikes*: string
  sep*: string          # Separator for filter combinations (default OR)
```

### TimelineKind
```nim
TimelineKind* {.pure.} = enum
  tweets, replies, media
```

### Video
```nim
Video* = object
  durationMs*: int
  url*: string
  thumb*: string
  available*: bool
  reason*: string
  title*: string
  description*: string
  playbackType*: VideoType
  variants*: seq[VideoVariant]

VideoVariant* = object
  contentType*: VideoType  # m3u8, mp4, vmap
  url*: string
  bitrate*: int
  resolution*: int
```

---

## Session/Authentication

Defined in `src/auth.nim`:

### initSessionPool
```nim
proc initSessionPool*(cfg: Config; path: string)
```
Initialize the session pool from a JSONL file containing account credentials.

**Parameters:**
- `cfg`: Config object (used for debug settings)
- `path`: Path to sessions JSONL file (e.g., `"sessions.jsonl"`)

**Session JSONL Format (OAuth):**
```json
{"username": "myuser", "oauthToken": "123456-xxxx", "oauthTokenSecret": "yyyy"}
```

**Session JSONL Format (Cookie):**
```json
{"kind": "cookie", "id": "123456", "username": "myuser", "authToken": "xxxx", "ct0": "yyyy"}
```

### getSessionPoolHealth
```nim
proc getSessionPoolHealth*(): JsonNode
```
Returns health information about the session pool as JSON.

### getSessionPoolDebug
```nim
proc getSessionPoolDebug*(): JsonNode
```
Returns detailed debug information about all sessions.

### setMaxConcurrentReqs
```nim
proc setMaxConcurrentReqs*(reqs: int)
```
Set maximum concurrent requests per session (default: 2).

---

## Configuration

Defined in `src/config.nim`:

### getConfig
```nim
proc getConfig*(path: string): (Config, parseCfg.Config)
```
Load configuration from a `.conf` file.

**Returns:** Tuple of (Config object, raw parseCfg.Config)

### Config Object
```nim
Config* = ref object
  address*: string          # Server address (default: "0.0.0.0")
  port*: int                # Server port (default: 8080)
  useHttps*: bool           # Use HTTPS (default: true)
  httpMaxConns*: int        # Max HTTP connections (default: 100)
  title*: string            # Instance title
  hostname*: string         # Instance hostname
  staticDir*: string        # Static files directory
  hmacKey*: string          # HMAC key for URL signing
  base64Media*: bool        # Use base64 encoding for media URLs
  enableRss*: bool          # Enable RSS feeds
  enableDebug*: bool        # Enable debug output
  proxy*: string            # Proxy URL
  proxyAuth*: string        # Proxy authentication
  apiProxy*: string         # API proxy URL
  disableTid*: bool         # Disable transaction ID
  maxConcurrentReqs*: int   # Max concurrent requests per session
  # Redis settings
  redisHost*: string
  redisPort*: int
  redisConns*: int
  redisMaxConns*: int
  redisPassword*: string
  # Cache settings
  rssCacheTime*: int
  listCacheTime*: int
```

---

## API Functions

Defined in `src/api.nim`. All functions are async.

### User Functions

#### getGraphUser
```nim
proc getGraphUser*(username: string): Future[User] {.async.}
```
Fetch a user by their screen name.

**Parameters:**
- `username`: Twitter/X username (without @)

**Returns:** `User` object

#### getGraphUserById
```nim
proc getGraphUserById*(id: string): Future[User] {.async.}
```
Fetch a user by their numeric ID.

**Parameters:**
- `id`: Numeric user ID as string

**Returns:** `User` object

### Timeline Functions

#### getGraphUserTweets
```nim
proc getGraphUserTweets*(id: string; kind: TimelineKind; after=""): Future[Profile] {.async.}
```
Fetch a user's timeline (tweets, replies, or media).

**Parameters:**
- `id`: User's numeric ID
- `kind`: `TimelineKind.tweets`, `TimelineKind.replies`, or `TimelineKind.media`
- `after`: Pagination cursor (optional)

**Returns:** `Profile` object containing `tweets: Timeline`

### Tweet Functions

#### getTweet
```nim
proc getTweet*(id: string; after=""): Future[Conversation] {.async.}
```
Fetch a single tweet with its conversation context.

**Parameters:**
- `id`: Tweet ID
- `after`: Pagination cursor for replies (optional)

**Returns:** `Conversation` object

#### getGraphTweetResult
```nim
proc getGraphTweetResult*(id: string): Future[Tweet] {.async.}
```
Fetch a single tweet without conversation context.

**Parameters:**
- `id`: Tweet ID

**Returns:** `Tweet` object

#### getReplies
```nim
proc getReplies*(id, after: string): Future[Result[Chain]] {.async.}
```
Fetch replies to a tweet with pagination.

**Parameters:**
- `id`: Tweet ID
- `after`: Pagination cursor

**Returns:** `Result[Chain]`

### Search Functions

#### getGraphTweetSearch
```nim
proc getGraphTweetSearch*(query: Query; after=""): Future[Timeline] {.async.}
```
Search for tweets.

**Parameters:**
- `query`: Query object specifying search parameters
- `after`: Pagination cursor (optional)

**Returns:** `Timeline` (Result[Tweets])

#### getGraphUserSearch
```nim
proc getGraphUserSearch*(query: Query; after=""): Future[Result[User]] {.async.}
```
Search for users.

**Parameters:**
- `query`: Query object with `text` field set
- `after`: Pagination cursor (optional)

**Returns:** `Result[User]`

### List Functions

#### getGraphList
```nim
proc getGraphList*(id: string): Future[List] {.async.}
```
Fetch a list by ID.

#### getGraphListBySlug
```nim
proc getGraphListBySlug*(name, list: string): Future[List] {.async.}
```
Fetch a list by username and list slug.

**Parameters:**
- `name`: Username who owns the list
- `list`: List slug/name

#### getGraphListTweets
```nim
proc getGraphListTweets*(id: string; after=""): Future[Timeline] {.async.}
```
Fetch tweets from a list.

#### getGraphListMembers
```nim
proc getGraphListMembers*(list: List; after=""): Future[Result[User]] {.async.}
```
Fetch members of a list.

### Media Functions

#### getPhotoRail
```nim
proc getPhotoRail*(id: string): Future[PhotoRail] {.async.}
```
Fetch the photo rail for a user (recent media thumbnails).

**Parameters:**
- `id`: User's numeric ID

**Returns:** `PhotoRail` (seq[GalleryPhoto])

---

## Query Building

Defined in `src/query.nim`:

### initQuery
```nim
proc initQuery*(pms: Table[string, string]; name=""): Query
```
Initialize a Query from URL parameters.

**Parameters:**
- `pms`: Table of parameter key-value pairs
- `name`: Username(s) to search from (comma-separated)

### getMediaQuery
```nim
proc getMediaQuery*(name: string): Query
```
Create a query for a user's media.

### getReplyQuery
```nim
proc getReplyQuery*(name: string): Query
```
Create a query for a user's replies.

### genQueryParam
```nim
proc genQueryParam*(query: Query): string
```
Generate a raw query string from a Query object.

**Example output:** `"from:username include:nativeretweets since:2024-01-01"`

### genQueryUrl
```nim
proc genQueryUrl*(query: Query): string
```
Generate a URL-encoded query string for search URLs.

### Valid Filters
```nim
validFilters* = @[
  "media", "images", "twimg", "videos",
  "native_video", "consumer_video", "spaces",
  "links", "news", "quote", "mentions",
  "replies", "retweets", "nativeretweets"
]
```

---

## Parsing Functions

Defined in `src/parser.nim`. These are mainly internal but can be useful:

### parseGraphUser
```nim
proc parseGraphUser(js: JsonNode): User
```
Parse a User from GraphQL JSON response.

### parseGraphList
```nim
proc parseGraphList*(js: JsonNode): List
```
Parse a List from GraphQL JSON response.

### parseGraphTimeline
```nim
proc parseGraphTimeline*(js: JsonNode; after=""): Profile
```
Parse a timeline response into a Profile.

### parseGraphConversation
```nim
proc parseGraphConversation*(js: JsonNode; tweetId: string): Conversation
```
Parse a conversation/tweet detail response.

### parseGraphSearch
```nim
proc parseGraphSearch*[T: User | Tweets](js: JsonNode; after=""): Result[T]
```
Parse search results (works for both user and tweet search).

### parseGraphTweetResult
```nim
proc parseGraphTweetResult*(js: JsonNode): Tweet
```
Parse a single tweet result.

---

## Utility Functions

### apiutils.nim

#### setApiProxy
```nim
proc setApiProxy*(url: string)
```
Set an API proxy URL for all requests.

#### setDisableTid
```nim
proc setDisableTid*(disable: bool)
```
Disable transaction ID generation (uses alternative bearer token).

### utils.nim

#### setHmacKey
```nim
proc setHmacKey*(key: string)
```
Set the HMAC key for URL signing.

#### setProxyEncoding
```nim
proc setProxyEncoding*(state: bool)
```
Enable/disable base64 encoding for proxied media URLs.

#### getVidUrl / getPicUrl / getOrigPicUrl
```nim
proc getVidUrl*(link: string): string
proc getPicUrl*(link: string): string
proc getOrigPicUrl*(link: string): string
```
Generate proxied URLs for media.

### formatters.nim

#### getTime
```nim
proc getTime*(tweet: Tweet): string
```
Format tweet time as "MMM d, YYYY · h:mm tt UTC"

#### getShortTime
```nim
proc getShortTime*(tweet: Tweet): string
```
Format tweet time as relative time (e.g., "5m", "2h", "Mar 15")

#### getLink
```nim
proc getLink*(tweet: Tweet; focus=true): string
```
Get the URL path for a tweet (e.g., "/username/status/123456")

#### pageTitle
```nim
proc pageTitle*(user: User): string
proc pageTitle*(tweet: Tweet): string
```
Generate page titles for users/tweets.

---

## Example Usage

### Basic Script Structure

```nim
import asyncdispatch
import types, config, auth, api, query, apiutils

proc main() {.async.} =
  # Load config
  let (cfg, _) = getConfig("nitter.conf")

  # Initialize sessions
  initSessionPool(cfg, "sessions.jsonl")

  # Optional: Set API proxy
  # setApiProxy("http://localhost:8080")

  # Fetch a user
  let user = await getGraphUser("elonmusk")
  echo "Username: ", user.username
  echo "Followers: ", user.followers

  # Fetch user's tweets
  let profile = await getGraphUserTweets(user.id, TimelineKind.tweets)
  for tweet in profile.tweets.content:
    echo tweet.text
    echo "---"

  # Search for tweets
  var searchQuery = Query(
    kind: QueryKind.tweets,
    text: "nim programming",
    since: "2024-01-01"
  )
  let results = await getGraphTweetSearch(searchQuery)
  for tweet in results.content:
    echo tweet.user.username, ": ", tweet.text

waitFor main()
```

### Pagination Example

```nim
proc fetchAllUserTweets(userId: string) {.async.} =
  var cursor = ""
  var allTweets: seq[Tweet] = @[]

  while true:
    let profile = await getGraphUserTweets(userId, TimelineKind.tweets, cursor)
    allTweets.add(profile.tweets.content)

    if profile.tweets.bottom.len == 0:
      break
    cursor = profile.tweets.bottom

  echo "Total tweets fetched: ", allTweets.len
```

### Search with Filters

```nim
proc searchWithFilters() {.async.} =
  var query = Query(
    kind: QueryKind.tweets,
    text: "breaking news",
    filters: @["images", "videos"],  # Has media
    excludes: @["retweets"],          # No retweets
    since: "2024-06-01",
    until: "2024-06-30",
    minLikes: "100"
  )

  let results = await getGraphTweetSearch(query)
  echo "Found ", results.content.len, " tweets"
```

---

## Session File Format

The `sessions.jsonl` file should contain one JSON object per line:

### OAuth Format (recommended)
```json
{"username": "account1", "oauthToken": "123456789-AbCdEfGh", "oauthTokenSecret": "secret123"}
{"username": "account2", "oauthToken": "987654321-XyZwVuTs", "oauthTokenSecret": "secret456"}
```

### Cookie Format
```json
{"kind": "cookie", "id": "123456789", "username": "account1", "authToken": "auth_token_here", "ct0": "csrf_token_here"}
```

You can generate OAuth credentials using the `tools/create_session_browser.py` script.

---

## Error Handling

The API uses exceptions for error handling:

- `RateLimitError`: Raised when rate limited (will auto-retry once)
- `NoSessionsError`: Raised when no valid sessions are available
- `InternalError`: Raised for internal API errors
- `BadClientError`: Raised when client is flagged (HTTP 503)

```nim
try:
  let user = await getGraphUser("someuser")
except RateLimitError:
  echo "Rate limited, try again later"
except NoSessionsError:
  echo "No sessions available"
```
