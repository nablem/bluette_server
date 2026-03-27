import Config

config :bluette_server,
  port: 4000,
  auth_verifier: BluetteServer.Auth.MockVerifier

config :bluette_server,
  ecto_repos: [BluetteServer.Repo]

config :bluette_server, BluetteServer.Repo,
  adapter: Ecto.Adapters.SQLite3,
  pool_size: 1,
  busy_timeout: 5_000

import_config "#{config_env()}.exs"
