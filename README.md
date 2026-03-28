# Bluette Server

Backend API for the Bluette mobile app — Elixir, Plug/Cowboy, Ecto/SQLite.

---

## Table of Contents

1. [Feature Scope](#feature-scope)
2. [Product Logic](#product-logic)
3. [Meeting Status Lifecycle](#meeting-status-lifecycle)
4. [Stack Filtering Rules](#stack-filtering-rules)
5. [Visibility Rank](#visibility-rank)
6. [Data Model](#data-model)
7. [API Reference](#api-reference)
8. [Error Codes](#error-codes)
9. [Realtime Events](#realtime-events)
10. [Frontend Flow](#frontend-flow)
11. [Auth](#auth)
12. [Local Setup](#local-setup)
13. [Development Utilities](#development-utilities)
14. [Tests](#tests)

---

## Feature Scope

- Firebase-based auth (mock in dev/test, real RS256 JWT verifier in prod).
- Profile and settings management with onboarding completeness tracking.
- Homepage swipe stack with preference + distance filtering.
- Mutual-like meeting creation with nearest open bar selection.
- Meeting status lifecycle: `upcoming` → `happening` → `due` / `cancelled`.
- Due meeting survey gate before returning to stack mode.
- Meeting lock: swiping disabled while a meeting is active.
- Cancellation with `visibility_rank` penalty.
- Bars catalog import from JSON with weekday open-hours checking.
- Notifications persistence and realtime stream via SSE.

---

## Product Logic

1. Users see one profile at a time in a swipe stack.
2. Each profile can be swiped `like` or `pass`.
3. A mutual `like` immediately creates a meeting at the nearest open bar.
4. While a meeting is `upcoming` or `happening`, the home screen shows meeting details and swiping is blocked.
5. Once a meeting reaches `due`, each user must answer a survey (`attended: true/false`) before stack mode is returned.
6. Survey scoring:
  - Both `true`: both users gain `+5` visibility rank.
  - Both `false`: both users lose `-5` visibility rank.
  - Mixed answers: no rank change.
7. Cancelling a meeting lowers the canceller's `visibility_rank` by 20 (floor 0).
8. Profiles that have an active meeting (`upcoming` or `happening`) are hidden from everyone else's stack.
9. A `pass` decision never creates a meeting, even if the other party already liked.

---

## Meeting Status Lifecycle

```
[future scheduled_for]
     upcoming
         │ scheduled_for reached
         ▼
     happening   ← stack still locked, 12h grace window
         │ scheduled_for + 12h reached
         ▼
      due       ← survey required before stack unlocks
```

Cancellation can happen from `upcoming` or `happening`:

```
     upcoming ──► cancelled  ← visibility_rank − 20
     happening ──► cancelled ← visibility_rank − 20
```

Status transitions are applied automatically on every call to `GET /api/v1/home`, `POST /api/v1/home/swipe`, `POST /api/v1/home/meeting/cancel`, and `POST /api/v1/home/meeting/survey`.

---

## Stack Filtering Rules

A candidate profile is shown only if **all** of the following are true:

1. The candidate has a complete profile (`name`, `age`, `gender`, `audio_bio`, `profile_picture`, all preferences, location).
2. The current user has not yet swiped on the candidate (any decision).
3. The candidate has no active meeting (`upcoming` or `happening`).
4. The candidate's `gender` matches the current user's `pref_gender` (or pref is `"everyone"`).
5. The candidate's `age` is within the current user's `pref_min_age`–`pref_max_age`.
6. The current user's `gender` matches the candidate's `pref_gender` (reciprocal).
7. The current user's `age` is within the candidate's `pref_min_age`–`pref_max_age` (reciprocal).
8. The haversine distance between the two users is within the current user's `pref_max_distance_km`.

Candidates are ordered by `visibility_rank` descending, then by `id` ascending.

---

## Visibility Rank

- Default: `100`.
- Cancelling a meeting: `−20` (floor `0`).
- Due survey result `both_yes`: `+5` for both users.
- Due survey result `both_no`: `−5` for both users.
- Higher rank = shown earlier in others' stacks.
- Reset is manual (no automatic recovery is implemented).

---

## Data Model

### `users`

| Field | Type | Notes |
|---|---|---|
| `firebase_uid` | string | unique, auth identity |
| `email` | string | |
| `name` | string | onboarding |
| `age` | integer | onboarding |
| `gender` | string | `male`, `female`, `other` |
| `audio_bio` | string | URL, onboarding |
| `profile_picture` | string | URL, onboarding |
| `latitude` | float | |
| `longitude` | float | |
| `pref_min_age` | integer | onboarding |
| `pref_max_age` | integer | onboarding |
| `pref_max_distance_km` | integer | onboarding |
| `pref_gender` | string | `male`, `female`, `other`, `everyone` — onboarding |
| `visibility_rank` | integer | default 100 |

### `swipes`

| Field | Type | Notes |
|---|---|---|
| `swiper_user_id` | integer | FK users |
| `swiped_user_id` | integer | FK users |
| `decision` | string | `like` or `pass` |

Unique constraint on `(swiper_user_id, swiped_user_id)`. Re-swiping upserts the decision.

### `meetings`

| Field | Type | Notes |
|---|---|---|
| `user_a_id` | integer | FK users |
| `user_b_id` | integer | FK users |
| `status` | string | `upcoming`, `happening`, `due`, `cancelled` |
| `scheduled_for` | utc_datetime | evening slot, Paris timezone |
| `place_name` | string | |
| `place_latitude` | float | |
| `place_longitude` | float | |
| `cancelled_by_user_id` | integer | FK users, nullable |
| `survey_outcome` | string | `both_yes`, `both_no`, `mixed` when both answers exist |
| `survey_resolved_at` | utc_datetime | nullable, set when both answers have been processed |

### `meeting_surveys`

| Field | Type | Notes |
|---|---|---|
| `meeting_id` | integer | FK meetings |
| `user_id` | integer | FK users |
| `attended` | boolean | `true` or `false` |
| `answered_at` | utc_datetime | |

Unique constraint on `(meeting_id, user_id)`.

### `bars`

| Field | Type | Notes |
|---|---|---|
| `google_place_id` | string | unique |
| `name` | string | |
| `address` | string | |
| `locality` | string | |
| `region_code` | string | |
| `latitude` | float | |
| `longitude` | float | |
| `availability` | map | `{ "monday": { "start": "HH:MM", "end": "HH:MM" }, … }` |
| `google_maps_uri` | string | |
| `timezone` | string | e.g. `Europe/Paris` |

---

## API Reference

All endpoints except `GET /health` require an `Authorization: Bearer <token>` header.
All request and response bodies are JSON. All timestamps are UTC ISO 8601.

---

### `GET /health`

No auth required.

**Response `200`:**
```json
{ "status": "ok", "service": "bluette_server" }
```

---

### `POST /api/v1/auth/verify`

Verifies the bearer token and upserts the user. Call this on every app launch.

**Response `200`:**
```json
{
  "authenticated": true,
  "user": {
    "uid": "user_1",
    "email": "user1@example.com",
    "name": "Nabil",
    "age": 27,
    "gender": "male",
    "audio_bio": "https://...",
    "profile_picture": "https://...",
    "latitude": 48.867,
    "longitude": 2.268
  }
}
```

**Response `401`:** Invalid or missing token.

---

### `GET /api/v1/profile`

Returns the current user's profile and preferences.

**Response `200`:**
```json
{
  "user": { "uid": "...", "email": "...", "name": "...", "age": 27, "gender": "male", "audio_bio": "...", "profile_picture": "...", "latitude": 48.867, "longitude": 2.268 },
  "preferences": { "min_age": 18, "max_age": 45, "max_distance_km": 50, "preferred_gender": "female" }
}
```

---

### `PUT /api/v1/profile/name`

**Body:** `{ "name": "Nabil" }`
**Response `200`:** `{ "user": { … } }`
**Response `422`:** `{ "error": "validation_failed", "details": { "name": ["…"] } }`

---

### `PUT /api/v1/profile/age`

**Body:** `{ "age": 27 }`
**Response `200`:** `{ "user": { … } }`
**Response `422`:** validation error

---

### `PUT /api/v1/profile/gender`

**Body:** `{ "gender": "male" }` — values: `male`, `female`, `other`
**Response `200`:** `{ "user": { … } }`
**Response `422`:** validation error

---

### `PUT /api/v1/profile/audio-bio`

**Body:** `{ "audio_bio": "https://…" }`
**Response `200`:** `{ "user": { … } }`
**Response `422`:** validation error

---

### `PUT /api/v1/profile/profile-picture`

**Body:** `{ "profile_picture": "https://…" }`
**Response `200`:** `{ "user": { … } }`
**Response `422`:** validation error

---

### `PUT /api/v1/profile/location`

**Body:** `{ "latitude": 48.867, "longitude": 2.268 }`
**Response `200`:** `{ "user": { … } }`
**Response `422`:** validation error

---

### `PUT /api/v1/profile/matching-preferences`

**Body:**
```json
{ "min_age": 18, "max_age": 45, "max_distance_km": 50, "preferred_gender": "female" }
```
`preferred_gender` values: `male`, `female`, `other`, `everyone`

**Response `200`:** `{ "preferences": { "min_age": …, "max_age": …, "max_distance_km": …, "preferred_gender": … } }`
**Response `422`:** validation error

---

### `DELETE /api/v1/profile`

Deletes the account entirely.

**Response `204`:** No body.
**Response `500`:** Unexpected error.

---

### `GET /api/v1/home`

Main polling endpoint. Applies status transitions before returning. Call this when the app launches or resumes.

**Stack mode** (no active meeting):
```json
{
  "home": {
    "mode": "stack",
    "can_swipe": true,
    "profile": {
      "uid": "seeded_user_2",
      "name": "Luna",
      "age": 26,
      "gender": "female",
      "audio_bio": "https://…",
      "profile_picture": "https://…"
    }
  }
}
```

`profile` is `null` when no candidates remain.

**Meeting mode** (active meeting exists):
```json
{
  "home": {
    "mode": "meeting",
    "can_swipe": false,
    "meeting": {
      "id": 1,
      "status": "upcoming",
      "scheduled_for": "2026-03-28T17:00:00Z",
      "place": {
        "name": "Bar 8",
        "latitude": 48.8669,
        "longitude": 2.3271
      },
      "with_user": {
        "uid": "seeded_user_17",
        "name": "Alice",
        "age": 20,
        "gender": "female",
        "audio_bio": "https://…",
        "profile_picture": "https://…"
      }
    }
  }
}
```

`meeting.status` can be `"upcoming"` (future) or `"happening"` (within 12h grace window). The app can use this to differentiate UI — e.g. show a countdown banner when `"happening"`.

**Survey mode** (meeting is due and current user has not answered yet):
```json
{
  "home": {
    "mode": "survey",
    "can_swipe": false,
    "survey": {
      "meeting": {
        "id": 1,
        "status": "due",
        "scheduled_for": "2026-03-28T17:00:00Z",
        "place": { "name": "Bar 8", "latitude": 48.8669, "longitude": 2.3271 },
        "with_user": { "uid": "seeded_user_17", "name": "Alice", "age": 20, "gender": "female", "audio_bio": "https://…", "profile_picture": "https://…" }
      }
    }
  }
}
```

While in `survey` mode, swiping returns `409 survey_pending` until the current user submits an answer.

**With incomplete onboarding** (additional key when profile is not complete):
```json
{
  "home": { "mode": "stack", "can_swipe": false, "profile": null },
  "onboarding": {
    "missing_fields": ["name", "age", "audio_bio"]
  }
}
```

When `missing_fields` is non-empty, direct the user to the settings screen before showing the stack.

---

### `POST /api/v1/home/swipe`

Records a swipe decision. Blocked while any active meeting exists.

**Body:** `{ "target_uid": "seeded_user_2", "decision": "like" }`

`decision` values: `like`, `pass`

**Response `200` — no match:**
```json
{
  "swipe": { "match_created": false },
  "home": { "mode": "stack", "can_swipe": true, "profile": { … } }
}
```

**Response `200` — match created:**
```json
{
  "swipe": {
    "match_created": true,
    "meeting": {
      "id": 1,
      "status": "upcoming",
      "scheduled_for": "2026-03-28T17:00:00Z",
      "place": { "name": "Bar 8", "latitude": 48.8669, "longitude": 2.3271 },
      "with_user": { "uid": "…", "name": "…", "age": 26, "gender": "female", "audio_bio": "…", "profile_picture": "…" }
    }
  },
  "home": { "mode": "meeting", "can_swipe": false, "meeting": { … } }
}
```

**Response `409`:** Blocked — see [Error Codes](#error-codes).
**Response `422`:** Missing or invalid fields.

---

### `POST /api/v1/home/meeting/cancel`

Cancels the current active meeting (`upcoming` or `happening`). Lowers the caller's `visibility_rank` by 20.

**Body:** `{}` (empty)

**Response `200`:**
```json
{
  "meeting": { "status": "cancelled" },
  "home": { "mode": "stack", "can_swipe": true, "profile": { … } }
}
```

The cancelled party's home will also return `stack` mode on their next poll.

**Response `404`:** `{ "error": "no_upcoming_meeting" }` — no active meeting to cancel.

---

### `POST /api/v1/home/meeting/survey`

Submits whether the current user attended the most recent pending due meeting.

**Body:** `{ "attended": true }`

**Response `200`:**
```json
{
  "home": { "mode": "stack", "can_swipe": true, "profile": { "uid": "seeded_user_2", "name": "Luna", "age": 26, "gender": "female", "audio_bio": "https://…", "profile_picture": "https://…" } }
}
```

**Response `404`:** `{ "error": "no_due_meeting_survey" }`

**Response `422`:**
```json
{ "error": "validation_failed", "details": { "attended": ["must be true or false"] } }
```

---

### `GET /api/v1/notifications`

Returns latest notifications for the authenticated user.

Query params:

- `limit` (optional, default `50`, max `200`)
- `after_id` (optional, only notification IDs greater than this value)

**Response `200`:**
```json
{
  "notifications": [
    {
      "id": 12,
      "event_type": "meeting_happening",
      "payload": {
        "meeting_id": 3,
        "meeting_status": "happening",
        "scheduled_for": "2026-03-28T17:00:00Z",
        "counterparty_uid": "seeded_user_17",
        "place": {
          "name": "Bar 8",
          "latitude": 48.8669,
          "longitude": 2.3271
        }
      },
      "read_at": null,
      "inserted_at": "2026-03-28T17:00:01Z"
    }
  ],
  "unread_count": 1
}
```

---

### `POST /api/v1/notifications/read`

Marks notifications as read.

Body variants:

- `{}` marks all unread notifications as read
- `{ "ids": [12, 15] }` marks only selected notifications as read

**Response `200`:**
```json
{ "updated": 2, "unread_count": 0 }
```

---

### `GET /api/v1/notifications/stream`

Server-Sent Events (SSE) stream for real-time updates.

Headers:

- `Authorization: Bearer <token>`
- `Accept: text/event-stream`

Event names:

- `connected`
- `notification`

SSE event example:
```text
event: notification
data: {"id":12,"event_type":"match_created","payload":{...},"read_at":null,"inserted_at":"2026-03-28T17:00:01Z"}
```

---

## Error Codes

| HTTP | `error` value | Meaning |
|---|---|---|
| `401` | `missing_bearer_token` | No `Authorization` header |
| `401` | `invalid_token` | Token failed verification |
| `404` | `not_found` | Route does not exist |
| `404` | `no_upcoming_meeting` | Cancel attempted with no active meeting |
| `404` | `no_due_meeting_survey` | Survey submit attempted without a pending due survey |
| `409` | `meeting_in_progress` | Swipe blocked — caller has an active meeting |
| `409` | `survey_pending` | Swipe blocked — caller must answer due meeting survey first |
| `409` | `target_unavailable` | Swipe blocked — target user has an active meeting |
| `409` | `target_not_found` | `target_uid` does not exist |
| `409` | `cannot_swipe_self` | `target_uid` matches the caller |
| `422` | `validation_failed` | Request body missing or invalid fields |

---

## Realtime Events

Current event types persisted and streamed to users:

- `match_created`: emitted for both users when reciprocal likes create a meeting.
- `meeting_happening`: emitted for both users when scheduled time is reached and meeting enters grace window.
- `meeting_due`: emitted for both users when `scheduled_for + 12h` is reached.
- `meeting_survey_required`: emitted for both users when meeting becomes `due` and survey answers are now required.
- `meeting_survey_resolved`: emitted for both users after both survey answers are submitted; payload includes `survey_outcome` and `rank_delta`.
- `meeting_cancelled`: emitted for both users when either user cancels; payload includes `cancelled_by_uid`.

Recommended client behavior:

1. Open `GET /api/v1/notifications/stream` right after successful auth.
2. On each `notification`, update local notification state and optionally call `GET /api/v1/home` to refresh home mode.
3. Call `POST /api/v1/notifications/read` after user consumes notifications.

---

## Frontend Flow

The backend is designed around `GET /api/v1/home` as canonical UI state. Use notification events as triggers and `home` payload as source of truth.

### 1) Launch and Auth

1. Authenticate user and call `POST /api/v1/auth/verify`.
2. Open `GET /api/v1/notifications/stream` once authenticated.
3. Call `GET /api/v1/home` and render based on `home.mode`.

### 2) Home State Machine

1. `home.mode == "stack"`: show swipe stack.
2. `home.mode == "meeting"`: show meetup card, disable swipe actions.
3. `home.mode == "survey"`: show yes/no due-meeting survey, disable swipe actions.

### 3) Swipe and Match

1. User swipes via `POST /api/v1/home/swipe`.
2. If response has `swipe.match_created == true`, switch immediately to meeting UI from returned `home` payload.
3. If match was created on the other device first, `match_created` notification should trigger `GET /api/v1/home` and transition to meeting UI.

### 4) Meeting Lifecycle Refreshes

Trigger `GET /api/v1/home` when receiving these events:

1. `match_created` (meeting appears)
2. `meeting_happening` (status UI update)
3. `meeting_due` or `meeting_survey_required` (survey appears)
4. `meeting_cancelled` (return to stack)
5. `meeting_survey_resolved` (result finalized)

### 5) Due Survey Flow

1. When `home.mode == "survey"`, ask: "Did you meet <name>?"
2. Submit answer with `POST /api/v1/home/meeting/survey` and `{ "attended": true | false }`.
3. Render UI from returned `home` payload.
4. If swipe API returns `409 survey_pending`, redirect to survey UI and refresh `GET /api/v1/home`.

### 6) Reconnect and Resync

1. On SSE reconnect, call `GET /api/v1/home` once.
2. On app resume/foreground, call `GET /api/v1/home` once.
3. Keep event handling idempotent; multiple events may map to the same current state.

### 7) Minimal Error Handling

1. `401`: refresh/reacquire auth token, then retry call.
2. `404 no_due_meeting_survey`: dismiss survey UI and refresh `GET /api/v1/home`.
3. `409 meeting_in_progress` or `409 survey_pending`: route to non-stack mode with `GET /api/v1/home`.
4. `422 validation_failed`: keep current screen and show inline validation message.

---

## Auth

### Environment split

| Environment | Verifier | Token format |
|---|---|---|
| `dev` | `MockVerifier` | `mock:<uid>:<email>` |
| `test` | `MockVerifier` | `mock:<uid>:<email>` |
| `prod` | `FirebaseVerifier` | Firebase RS256 JWT |

### Mock token format

`Authorization: Bearer mock:user_1:user1@example.com`

### Firebase (prod)

Set `FIREBASE_PROJECT_ID` env var. Application fails to start if missing.

### Flutter mobile test flow

1. Enable Google sign-in in Firebase console.
2. Sign in from Flutter using `firebase_auth`.
3. Get ID token: `await FirebaseAuth.instance.currentUser!.getIdToken()`
4. Send as bearer: `Authorization: Bearer <id_token>`
5. Call `POST /api/v1/auth/verify` — expect `200 authenticated: true`.

Android emulator: replace `localhost` with `10.0.2.2`.

---

## Local Setup

```sh
mix deps.get
mix ecto.migrate
mix bluette.import_bars          # load bars catalog
mix bluette.seed_fake_profiles   # 30 fake users
mix run --no-halt                # server at http://localhost:4000
```

---

## Development Utilities

### Seed profiles

```sh
mix bluette.seed_fake_profiles
mix bluette.seed_fake_profiles 50
```

### Import bars catalog

```sh
mix bluette.import_bars
mix bluette.import_bars bars.json
```

### IEx helpers

Start console: `iex -S mix`

**Make all seeded profiles like your mock user** (next like you send triggers a match):
```elixir
alias BluetteServer.{Repo, Accounts.Swipe, Accounts.User}; import Ecto.Query; target = Repo.get_by!(User, firebase_uid: "user_1"); now = DateTime.utc_now() |> DateTime.truncate(:second); entries = Repo.all(from u in User, where: u.firebase_uid != "user_1") |> Enum.map(&%{swiper_user_id: &1.id, swiped_user_id: target.id, decision: "like", inserted_at: now, updated_at: now}); Repo.insert_all(Swipe, entries, on_conflict: {:replace, [:decision, :updated_at]}, conflict_target: [:swiper_user_id, :swiped_user_id])
```

**Reset all swipes** (restore full stack):
```elixir
alias BluetteServer.{Repo, Accounts.Swipe}; Repo.delete_all(Swipe)
```

**Check your visibility rank:**
```elixir
alias BluetteServer.{Repo, Accounts.User}; Repo.get_by!(User, firebase_uid: "user_1").visibility_rank
```

**Clear onboarding fields:**
```elixir
BluetteServer.Accounts.clear_user_details("user_1")
```

---

## Tests

```sh
mix test
```

66 tests, covering: auth verifiers, profile settings, onboarding, stack filtering, swipe decisions, match creation, meeting lifecycle (upcoming → happening → due), due survey gating and scoring, cancellation, visibility rank, realtime notifications persistence, concurrency safety for survey submissions, and edge cases (pass with reciprocal like, swipe during happening meeting, cancel with no meeting, other party's view after cancel).

