import Config

auth_verifier =
  case String.downcase(System.get_env("AUTH_VERIFIER", "firebase")) do
    "firebase" -> BluetteServer.Auth.FirebaseVerifier
    "mock" -> BluetteServer.Auth.MockVerifier
    value -> raise "Invalid AUTH_VERIFIER=#{inspect(value)}. Expected 'firebase' or 'mock'."
  end

config :bluette_server,
  port: 4000,
  auth_verifier: auth_verifier,
  firebase_project_id: System.get_env("FIREBASE_PROJECT_ID")

config :bluette_server, BluetteServer.Repo,
  database: System.get_env("DATABASE_PATH", "/var/lib/bluette_server/bluette_server.db"),
  journal_mode: :wal

config :tzdata, :autoupdate, :disabled
