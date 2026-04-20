import Config

config :bluette_server,
  port: 80,
  auth_verifier: BluetteServer.Auth.FirebaseVerifier,
  firebase_project_id: System.get_env("FIREBASE_PROJECT_ID")

config :bluette_server, BluetteServer.Repo,
  database: System.get_env("DATABASE_PATH", "/var/lib/bluette_server/bluette_server.db"),
  journal_mode: :wal
