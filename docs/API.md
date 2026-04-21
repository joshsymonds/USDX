# SoundStage HTTP API

The SoundStage companion service (a Go queue manager) talks to USDX over a small unauthenticated HTTP API bound to TCP port 9000. This fork adds the server; the contract here is what SoundStage must implement against.

## Threat model

- **No authentication.** Trusted-LAN only. USDX binds to all interfaces by default; OS-level firewalling is the recommended mitigation when the host roams onto untrusted networks (e.g., a Steam Deck leaving its home dock).
- **Single client.** Written assuming one Go instance on the same LAN. No rate limiting; body size capped at 64 KB on `/queue`.
- **No persistence.** The queue is in-memory and dies with the USDX process. Re-populating state after a USDX restart is SoundStage's responsibility.

## Configuration

```ini
[SoundStage]
Port=9000        ; Clamped to [1024,65535], default 9000
```

Set in USDX's `config.ini`. Out-of-range values log a warning and fall back to `9000`.

## Content types

- **Request bodies**: `application/json` (must parse; malformed → `400`).
- **Responses**: `application/json` on all status codes, including errors. Error shape: `{"error": "<string>"}`.

## State model

USDX exposes one **`QueuedSong` slot** — a single staged "next up" song, not a multi-entry queue. SoundStage owns the real queue; USDX only holds what's currently staged for the Deck-user to pull.

The slot is manipulated by the endpoints described below plus the user's keyboard:
- **`POST /queue`** writes the slot (newest wins, replaces any previous contents).
- **Enter/Space on ScreenNextUp** consumes the slot, applies state, and transitions to ScreenSing. The slot becomes empty.
- **Esc/Backspace on ScreenNextUp** returns to ScreenMain *preserving* the slot so the user can retry.
- **Sing button on ScreenMain** (`S` key or Enter on Solo option) diverts to ScreenNextUp if the slot is populated; otherwise falls through to the normal song-selection flow.

**Push vs pull:** `/queue` always *stages* the song. If USDX is currently on `ScreenScore` (between songs), `/queue` *additionally* fades to ScreenNextUp immediately since nothing else is in motion. Everywhere else the user must press Sing to pull.

**Session lock:** Player count (1P vs 2P) is locked for the duration of a session, established at the first `/queue` of that session. A session starts when a `/queue` is received on ScreenMain and ends when the user returns to ScreenMain. The `players` field in `/queue` is honored only when USDX is on ScreenMain; silently ignored on ScreenScore (session in progress).

## Endpoints

### `POST /queue`

Stage a song into the `QueuedSong` slot. Replaces any existing stage. Does NOT transition the UI away from ScreenMain (Deck user pulls via the Sing button); DOES transition from ScreenScore (push handoff).

**Request body:**

```json
{
  "songId": "a1b2c3d4e5f67890",
  "requester": "Alice",
  "players": 2
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `songId` | string | yes | Stable 16-hex-char content hash of the song. Fetch from `/songs`. See "Stable song IDs" below. |
| `requester` | string | yes | Name of the person requesting — becomes Player 1's HUD label. Non-empty. |
| `players` | integer | no (default 1) | `1` or `2`. Honored only when USDX is on ScreenMain; silently ignored on ScreenScore. |

**Responses:**

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"playing"}` | Queue slot populated; from ScreenScore also triggered handoff transition |
| `400` | `{"error":"malformed json"}` | Body didn't parse as JSON |
| `400` | `{"error":"body must be an object"}` | Parsed to a non-object (array, number, etc.) |
| `400` | `{"error":"legacy fields removed; use requester"}` | Body contains `singer` or `singers` (v1 API shape — rejected outright, no shim) |
| `400` | `{"error":"songId required (string)"}` | Missing, non-string, or empty `songId` (integer IDs are no longer accepted) |
| `400` | `{"error":"requester required"}` | Missing or empty `requester` |
| `400` | `{"error":"players must be 1 or 2"}` | `players` present but not a JSON integer ∈ {1,2} |
| `409` | `{"error":"song in progress"}` | USDX is on ScreenSing (mid-song); queue is untouched |
| `413` | `{"error":"body too large"}` | Body exceeds 64 KB |
| `404` | `{"error":"unknown songId"}` | `songId` does not match any loaded song |
| `504` | `{"error":"timeout"}` | Main thread didn't drain the command within 10 s (rare; under severe load) |
| `500` | `{"error":"internal"}` | Unhandled exception; check USDX's `Error.log` |

**Idempotency:** none. Re-posting the same body replaces the slot (newest wins). Posting different bodies in succession discards previous stages.

**Example:**

```sh
curl -X POST http://deck:9000/queue \
  -H 'Content-Type: application/json' \
  -d '{"songId":"a1b2c3d4e5f67890","requester":"Alice","players":2}'
# → 200 {"status":"playing"}
```

### `GET /songs`

Return the full song library visible to USDX. Category header entries are omitted. Order matches USDX's current sort setting; it is **not** a stable iteration order — use `id` for identity.

**Response (`200`):**

```json
[
  {"id": "a1b2c3d4e5f67890", "title": "I'm Not In Love", "artist": "10cc", "duet": false},
  {"id": "9988776655443322", "title": "What's Up?", "artist": "4 Non Blondes", "duet": false},
  {"id": "deadbeef01234567", "title": "Islands in the Stream", "artist": "Kenny Rogers & Dolly Parton", "duet": true},
  ...
]
```

| Field | Type | Description |
|---|---|---|
| `id` | string | Stable 16-hex-char content hash. Persists across `CatSongs.Refresh`, restarts, and file moves. |
| `title` | string | Song title. |
| `artist` | string | Song artist. |
| `duet` | boolean | Whether the song has duet (P1/P2) note sections. Affects how it's scored; also factors into the `id` hash. |

Potentially several thousand entries on a large library; worst-case ~80 KB wire. Serialization is O(N) via internal string builder.

### `GET /now-playing`

Current song state. Returns `null` unless USDX is actively on ScreenSing with audio playing — ScreenNextUp, ScreenScore, and finished-audio all return `null` regardless of queue state.

**Response:** `null` or

```json
{
  "id": "deadbeef01234567",
  "title": "Take On Me",
  "artist": "a-ha",
  "elapsed": 42.715,
  "duration": 243.981
}
```

Times are in seconds. `id` is the stable hash. Always HTTP `200`.

### `POST /pause`

Pause the currently-playing song's audio stream. Returns `409 {"error":"not playing"}` if no audio is active. `200 {"status":"paused"}` on success. No body.

### `POST /resume`

Resume a paused stream. `409 {"error":"nothing to resume"}` if none active. `200 {"status":"resumed"}` on success. No body.

### `GET /debug/state`

Internal state dump. Intended for development iteration; not part of the stable integration surface. Shape may change without notice.

**Response (`200`):**

```json
{
  "screen": "ScreenSing",
  "iniPlayers": 1,
  "playersPlay": 2,
  "audioFinished": false,
  "iniName": ["Alice", "Player 2", "Player3", ...],
  "player": [
    {"name": "Alice", "level": 1},
    {"name": "Player 2", "level": 1}
  ],
  "screenSingPlayerNames": ["Alice", "Player 2", "", ...],
  "currentSong": {"id": "deadbeef01234567", "title": "Take On Me", "artist": "a-ha"},
  "queuedSong": {
    "songId": "cafebabe89abcdef",
    "requester": "Charlie",
    "is2P": false,
    "title": "Dancing Queen",
    "artist": "ABBA"
  }
}
```

- `screen`: one of `"ScreenMain"`, `"ScreenSing"`, `"ScreenScore"`, `"ScreenNextUp"`, `"other"`, `"nil"`.
- `iniPlayers`: index into `IPlayersVals = (1,2,3,4,6)`. `0` = 1 player, `1` = 2 players, etc.
- `playersPlay`: actual count derived from above; drives `SetLength(Player, ...)`.
- `currentSong.id` and `queuedSong.songId` are stable content hashes matching the `id` values from `/songs`.
- `queuedSong`: `null` when the slot is empty (consumed or never written).

## Stable song IDs

Each song has a deterministic 16-hex-char `id` computed at load time as:

```
id = lowercase(md5(
    lowercase(trim(artist)) + "\0" +
    lowercase(trim(title))  + "\0" +
    (duet ? "1" : "0")
)[0:16])
```

Properties:

- **Stable across `CatSongs.Refresh` and restarts.** Persists as long as the song's normalized (artist, title, duet) doesn't change.
- **Stable across file moves.** The `id` is content-addressed, not path-addressed.
- **Unstable under metadata edits.** Renaming `artist` or `title`, or flipping duet status, changes the `id`.
- **Collisions are logged and first-wins.** Two files with identical normalized (artist, title, duet) will produce the same hash. USDX keeps the first one loaded and logs both paths; the user can disambiguate by editing metadata on one file (e.g., adding `(Cover)` to the title).
- **ASCII-normalized only.** Unicode case-folding is NOT performed. Case differences across non-ASCII characters in `artist`/`title` will produce distinct IDs. Not expected to matter in practice.

Cache the `id → (title, artist, duet)` mapping aggressively on SoundStage's side; on a `404 unknown songId` response from `/queue`, refetch `/songs` to pick up rename/removal events.

## Lifecycle signals

- USDX gracefully releases port 9000 on `SIGTERM` / `SIGINT` (Unix). Any in-flight requests receive `503 {"error":"shutting down"}`.
- On restart, all state is lost (queue, session lock, player names). SoundStage should re-establish by calling `/queue` fresh.

## Version

This document describes the API after the stable-song-IDs migration landed on `master`. No versioning header is sent; add one if the shape diverges from what's here.
