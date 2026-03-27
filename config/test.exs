import Config

config :bluette_server,
  auth_verifier: BluetteServer.Auth.MockVerifier

config :bluette_server, BluetteServer.Repo,
  database: "bluette_server_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

config :bluette_server,
  start_server: false

config :logger, level: :warning
