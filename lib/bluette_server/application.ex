defmodule BluetteServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [BluetteServer.Repo]
      |> maybe_add_http_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: BluetteServer.Supervisor)
  end

  defp port do
    Application.get_env(:bluette_server, :port, 4000)
  end

  defp maybe_add_http_server(children) do
    if Application.get_env(:bluette_server, :start_server, true) do
      children ++
        [
          {Plug.Cowboy,
           scheme: :http,
           plug: BluetteServer.Router,
           options: [port: port()]}
        ]
    else
      children
    end
  end
end
