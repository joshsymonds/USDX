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
  "songId": 42,
  "requester": "Alice",
  "players": 2
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `songId` | integer | yes | Index into the `/songs` array at stage time. See "Song identity caveat" below. |
| `requester` | string | yes | Name of the person requesting — becomes Player 1's HUD label. Non-empty. |
| `players` | integer | no (default 1) | `1` or `2`. Honored only when USDX is on ScreenMain; silently ignored on ScreenScore. |

**Responses:**

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"playing"}` | Queue slot populated; from ScreenScore also triggered handoff transition |
| `400` | `{"error":"malformed json"}` | Body didn't parse as JSON |
| `400` | `{"error":"body must be an object"}` | Parsed to a non-object (array, number, etc.) |
| `400` | `{"error":"legacy fields removed; use requester"}` | Body contains `singer` or `singers` (v1 API shape — rejected outright, no shim) |
| `400` | `{"error":"requester required"}` | Missing or empty `requester` |
| `400` | `{"error":"players must be 1 or 2"}` | `players` present but not a JSON integer ∈ {1,2} |
| `409` | `{"error":"song in progress"}` | USDX is on ScreenSing (mid-song); queue is untouched |
| `413` | `{"error":"body too large"}` | Body exceeds 64 KB |
| `404` | `{"error":"song not found"}` | `songId` out of range even after a `CatSongs.Refresh` retry |
| `504` | `{"error":"timeout"}` | Main thread didn't drain the command within 10 s (rare; under severe load) |
| `500` | `{"error":"internal"}` | Unhandled exception; check USDX's `Error.log` |

**Idempotency:** none. Re-posting the same body replaces the slot (newest wins). Posting different bodies in succession discards previous stages.

**Example:**

```sh
curl -X POST http://deck:9000/queue \
  -H 'Content-Type: application/json' \
  -d '{"songId":42,"requester":"Alice","players":2}'
# → 200 {"status":"playing"}
```

### `GET /songs`

Return the full song library visible to USDX, in the order they appear in `CatSongs.Song`. SoundStage should cache this and invalidate on any `/queue` response of `404 song not found` (indicating the index space changed — user added or removed files).

**Response (`200`):**

```json
[
  {"id": 0, "title": "I'm Not In Love", "artist": "10cc"},
  {"id": 1, "title": "What's Up?", "artist": "4 Non Blondes"},
  ...
]
```

Potentially several thousand entries on a large library; worst-case ~60 KB wire. Serialization is O(N) via internal string builder.

### `GET /now-playing`

Current song state. Returns `null` unless USDX is actively on ScreenSing with audio playing — ScreenNextUp, ScreenScore, and finished-audio all return `null` regardless of queue state.

**Response:** `null` or

```json
{
  "title": "Take On Me",
  "artist": "a-ha",
  "elapsed": 42.715,
  "duration": 243.981
}
```

Times are in seconds. Always HTTP `200`.

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
  "currentSong": {"id": 15, "title": "Take On Me", "artist": "a-ha"},
  "queuedSong": {
    "songId": 28,
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
- `queuedSong`: `null` when the slot is empty (consumed or never written).

## Song identity caveat

`songId` is the runtime index into USDX's `CatSongs.Song` array. This index is **not stable across `CatSongs.Refresh`** — if songs are added or removed on disk, indices shift. SoundStage should:

1. Fetch `/songs` at startup (or on cache miss) and cache the `id ↔ (title, artist)` mapping.
2. On any `404 song not found` from `/queue`, invalidate the cache and refetch.

A future version of this API may replace integer `songId` with a stable hash (`MD5(artist + "\0" + title + "\0" + duet)`). Until then, treat the index as a short-lived handle.

## Lifecycle signals

- USDX gracefully releases port 9000 on `SIGTERM` / `SIGINT` (Unix). Any in-flight requests receive `503 {"error":"shutting down"}`.
- On restart, all state is lost (queue, session lock, player names). SoundStage should re-establish by calling `/queue` fresh.

## Version

This document describes the API after Epic #11 + Epic #12 landed (merge commit `d8db991` on `master`). No versioning header is sent; add one if the shape diverges from what's here.
