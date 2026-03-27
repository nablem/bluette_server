import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :bluette_server,
  port: 4000

config :bluette_server,
  ecto_repos: [BluetteServer.Repo]

config :bluette_server, BluetteServer.Repo,
  adapter: Ecto.Adapters.SQLite3,
  pool_size: 1,
  busy_timeout: 5_000

import_config "#{config_env()}.exs"
