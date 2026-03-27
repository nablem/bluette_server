# Bluette Server

Backend API for the Bluette mobile app (Elixir, Plug/Cowboy, Ecto).

## Current Feature Scope

- Firebase-based authentication boundary (mock in dev/test, real verifier in prod).
- Profile and settings management.
- Onboarding completeness tracking.
- Homepage swipe stack.
- Mutual-like meeting creation.
- Meeting lock behavior: while a meeting is upcoming, swiping is disabled.
- Meeting cancellation with visibility-rank penalty.
- Automatic due-meeting transition (when scheduled time passes, stack returns).
- Bars catalog import from JSON and nearest-open-bar selection for meetings.
- Fake profile seeding for local development.

## Core Homepage Product Logic

1. Users see a stack of profiles one by one.
2. Each profile can be swiped with `like` or `pass`.
3. A mutual `like` creates a meeting instantly.
4. While a meeting is upcoming, homepage shows meeting details and swiping is blocked.
5. Stack returns when meeting is cancelled or when scheduled time is reached (meeting becomes `due`).
6. Cancelling a meeting lowers the canceller's `visibility_rank`.
7. Profiles with an upcoming meeting are hidden from everyone else's stack.
8. Meeting place is the nearest bar that is open at the selected meeting slot (Paris timezone).

## Data Model Overview

### `users`

- Auth identity: `firebase_uid`, `email`.
- Profile: `name`, `age`, `gender`, `audio_bio`, `profile_picture`.
- Location: `latitude`, `longitude`.
- Preferences: `pref_min_age`, `pref_max_age`, `pref_max_distance_km`, `pref_gender`.
- Ranking: `visibility_rank` (lowered on meeting cancellation).

### `swipes`

- `swiper_user_id`, `swiped_user_id`, `decision` (`like` or `pass`).
- Unique pair index prevents duplicate rows for the same directed pair.
- Re-swiping updates the existing decision.

### `meetings`

- `user_a_id`, `user_b_id`.
- `status` (`upcoming`, `due`, or `cancelled`).
- `scheduled_for` (between next day and 72h, evening slot, Paris timezone).
- `place_name`, `place_latitude`, `place_longitude`.
- `cancelled_by_user_id`.

### `bars`

- `google_place_id`, `name`, `address`, `locality`, `region_code`.
- `latitude`, `longitude`.
- `availability` (weekday opening windows).
- `google_maps_uri`, `timezone`.

## API Endpoints

### Health

- `GET /health`

### Auth

- `POST /api/v1/auth/verify`
  - Uses bearer token claims to upsert/fetch user.

### Profile / Settings

- `GET /api/v1/profile`
- `PUT /api/v1/profile/name`
- `PUT /api/v1/profile/age`
- `PUT /api/v1/profile/gender`
- `PUT /api/v1/profile/audio-bio`
- `PUT /api/v1/profile/profile-picture`
- `PUT /api/v1/profile/location`
- `PUT /api/v1/profile/matching-preferences`
- `DELETE /api/v1/profile`

### Homepage / Matching

- `GET /api/v1/home`
  - Returns `home.mode = "stack"` with next profile, or `home.mode = "meeting"` with upcoming meeting.
  - Adds onboarding payload when profile is incomplete.
- `POST /api/v1/home/swipe`
  - Body: `{ "target_uid": "...", "decision": "like" | "pass" }`
  - On mutual like: creates meeting and returns `match_created: true`.
- `POST /api/v1/home/meeting/cancel`
  - Cancels current upcoming meeting and restores stack mode.

Meeting scheduling details:

- Schedules in evening slots over next day to 72h (Paris timezone).
- Chooses nearest bar that is open at that exact slot.
- Falls back to placeholder place only if bars catalog is empty.

## Auth Verifier by Environment

- dev/test: `BluetteServer.Auth.MockVerifier`
- prod: `BluetteServer.Auth.FirebaseVerifier`

When Firebase verifier is active, `firebase_project_id` must be configured.
Application startup fails fast if it is missing.

## Local Setup

1. Install dependencies:

   mix deps.get

2. Run migrations:

   mix ecto.migrate

3. Start server:

   mix run --no-halt

4. Base URL:

   http://localhost:4000

## Mock Token Format (dev/test)

`mock:<uid>:<email>`

Examples:

- `mock:user_1:user1@example.com`
- `mock:nabil:nabil@example.com`

## Firebase Mobile Test Flow

1. Enable Google sign-in in Firebase.
2. Sign in from Flutter using Firebase Auth.
3. Send Firebase ID token as bearer token to `POST /api/v1/auth/verify`.
4. Expect `200` with `authenticated: true` and matching `uid/email`.
5. Use the same bearer token on protected endpoints.

Android emulator note: use `10.0.2.2` instead of `localhost`.

## Development Utilities

Seed fake completed profiles:

- `mix bluette.seed_fake_profiles`
- `mix bluette.seed_fake_profiles 50`

Import bars catalog JSON (default root file or custom path):

- `mix bluette.import_bars`
- `mix bluette.import_bars bars_Paris_1st_arrondissement.json`

Clear onboarding details via iex:

- `BluetteServer.Accounts.clear_user_details("user_1")`

## Tests

Run full suite:

`mix test`

