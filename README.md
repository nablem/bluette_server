# Bluette Server

Backend API for the Bluette mobile app.

This repository currently contains Iteration 2:

- Local HTTP server (Plug + Cowboy)
- SQLite database via Ecto
- Auth login/verify endpoint with user upsert
- Field-based profile detail endpoints
- Home endpoint placeholder
- ExUnit coverage for onboarding behavior

## Run Locally

1. Install dependencies:

  mix deps.get

2. Start server:

  mix run --no-halt

3. API base URL:

  http://localhost:4000

## Postman Checks

Health check:

- Method: GET
- URL: http://localhost:4000/health

Auth verify/login (creates user if missing):

- Method: POST
- URL: http://localhost:4000/api/v1/auth/verify
- Header: Authorization = Bearer mock:user_1:user1@example.com

Update name:

- Method: PUT
- URL: http://localhost:4000/api/v1/profile/name
- Header: Authorization = Bearer mock:user_1:user1@example.com
- Body (JSON): {"name":"Nabil"}

Update age:

- Method: PUT
- URL: http://localhost:4000/api/v1/profile/age
- Header: Authorization = Bearer mock:user_1:user1@example.com
- Body (JSON): {"age":27}
- Rule: age must be between 18 and 120 (inclusive)

Update audio bio:

- Method: PUT
- URL: http://localhost:4000/api/v1/profile/audio-bio
- Header: Authorization = Bearer mock:user_1:user1@example.com
- Body (JSON): {"audio_bio":"https://firebasestorage.googleapis.com/v0/b/bluette/o/audio1.m4a"}
- Rule: must be a valid http/https URL (Firebase Storage URL)

Update profile picture:

- Method: PUT
- URL: http://localhost:4000/api/v1/profile/profile-picture
- Header: Authorization = Bearer mock:user_1:user1@example.com
- Body (JSON): {"profile_picture":"https://firebasestorage.googleapis.com/v0/b/bluette/o/selfie1.jpg"}
- Rule: must be a valid http/https URL (Firebase Storage URL)

Home (empty payload for now):

- Method: GET
- URL: http://localhost:4000/api/v1/home
- Header: Authorization = Bearer mock:user_1:user1@example.com

Home response behavior:

- Returns {"home":{}} when onboarding is complete
- Returns {"home":{},"onboarding":...} only when fields are still missing

Unauthorized example:

- Method: POST
- URL: http://localhost:4000/api/v1/auth/verify
- No Authorization header

## Token Format (Current Mock)

For local development, the mock verifier accepts:

mock:<uid>:<email>

Examples:

- mock:user_1:user1@example.com
- mock:nabil:nabil@example.com

## Tests

Run tests at each iteration:

mix test

## Development Utilities

Seed 30 fake completed profiles:

mix bluette.seed_fake_profiles

Seed a custom number of fake completed profiles:

mix bluette.seed_fake_profiles 50

Clear onboarding details for the mock bearer user via iex:

iex> BluetteServer.Accounts.clear_user_details("user_1")
{:ok, %BluetteServer.Accounts.User{...}}

Clear onboarding details for a specific user by Firebase uid via iex:

iex> BluetteServer.Accounts.clear_user_details("user_42")
{:ok, %BluetteServer.Accounts.User{...}}

Current suite covers:

- Mock token parsing
- Auth login with user upsert
- Field-based profile detail validation and update path
- Home placeholder endpoint response

