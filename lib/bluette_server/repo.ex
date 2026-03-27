defmodule BluetteServer.Repo do
  use Ecto.Repo,
    otp_app: :bluette_server,
    adapter: Ecto.Adapters.SQLite3
end
