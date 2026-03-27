defmodule BluetteServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    validate_auth_config!()

    children =
      [
        BluetteServer.Repo,
        {Registry, keys: :duplicate, name: BluetteServer.Notifications.Registry}
      ]
      |> maybe_add_http_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: BluetteServer.Supervisor)
  end

  defp validate_auth_config! do
    auth_verifier =
      Application.get_env(:bluette_server, :auth_verifier, BluetteServer.Auth.MockVerifier)

    if auth_verifier == BluetteServer.Auth.FirebaseVerifier do
      project_id = Application.get_env(:bluette_server, :firebase_project_id)

      if not (is_binary(project_id) and project_id != "") do
        raise "firebase_project_id is required when using BluetteServer.Auth.FirebaseVerifier"
      end
    end
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
