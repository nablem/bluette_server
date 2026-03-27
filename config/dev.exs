import Config

config :bluette_server, BluetteServer.Repo,
  database: "bluette_server_dev.db",
  journal_mode: :wal
