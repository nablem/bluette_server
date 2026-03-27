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

Environment auth verifier setup:

- dev/test: `BluetteServer.Auth.MockVerifier`
- prod: `BluetteServer.Auth.FirebaseVerifier`

When `BluetteServer.Auth.FirebaseVerifier` is active, `firebase_project_id` must be configured.

## Test Firebase Auth From Flutter

Use this flow when the mobile app is connected to your backend.

1. In Firebase Console, add your Flutter app and enable Google Sign-In.
2. Start backend with Firebase verifier and project id configured.
3. In Flutter, sign in with Firebase Auth, fetch the ID token, and call `/api/v1/auth/verify` with `Authorization: Bearer <id_token>`.
4. Verify backend response is `200` with `authenticated: true` and a `user.uid` matching Firebase `uid`.

Expected backend request:

- Method: `POST`
- URL: `http://<your-backend-host>:4000/api/v1/auth/verify`
- Headers:
  - `Authorization: Bearer <firebase_id_token>`

Expected success response shape:

- `authenticated: true`
- `user.uid` = Firebase uid
- `user.email` = Firebase email

Expected failure cases:

- Missing/invalid bearer token -> `401`
- Expired token -> `401`
- Wrong Firebase project token (`aud` mismatch) -> `401`

Minimal Flutter call example:

```dart
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

Future<void> verifyWithBackend() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) throw Exception('No signed-in user');

  final idToken = await user.getIdToken(true);
  final uri = Uri.parse('http://10.0.2.2:4000/api/v1/auth/verify');

  final response = await http.post(
    uri,
    headers: {
      'Authorization': 'Bearer $idToken',
      'Content-Type': 'application/json',
    },
  );

  if (response.statusCode != 200) {
    throw Exception('Backend auth failed: ${response.statusCode} ${response.body}');
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  if (body['authenticated'] != true) {
    throw Exception('Unexpected backend auth response: $body');
  }
}
```

Android emulator note:

- Use `10.0.2.2` instead of `localhost` to reach backend running on your machine.

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

