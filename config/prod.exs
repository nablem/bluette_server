import Config

config :bluette_server,
  auth_verifier: BluetteServer.Auth.FirebaseVerifier,
  firebase_project_id: System.get_env("FIREBASE_PROJECT_ID")
