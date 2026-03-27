defmodule BluetteServer.Router do
  use Plug.Router

  alias BluetteServer.Accounts

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  get "/health" do
    send_json(conn, 200, %{status: "ok", service: "bluette_server"})
  end

  post "/api/v1/auth/verify" do
    with_authenticated_user(conn, fn conn, user ->
      send_json(conn, 200, %{authenticated: true, user: Accounts.user_response(user)})
    end)
  end

  put "/api/v1/profile/name" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{"name" => conn.body_params["name"]}

      case Accounts.update_name(user, attrs) do
        {:ok, updated_user} ->
          send_json(conn, 200, %{user: Accounts.user_response(updated_user)})

        {:error, changeset} ->
          send_json(conn, 422, %{error: "validation_failed", details: Accounts.errors_on(changeset)})
      end
    end)
  end

  put "/api/v1/profile/age" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{"age" => conn.body_params["age"]}

      case Accounts.update_age(user, attrs) do
        {:ok, updated_user} ->
          send_json(conn, 200, %{user: Accounts.user_response(updated_user)})

        {:error, changeset} ->
          send_json(conn, 422, %{error: "validation_failed", details: Accounts.errors_on(changeset)})
      end
    end)
  end

  put "/api/v1/profile/audio-bio" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{"audio_bio" => conn.body_params["audio_bio"]}

      case Accounts.update_audio_bio(user, attrs) do
        {:ok, updated_user} ->
          send_json(conn, 200, %{user: Accounts.user_response(updated_user)})

        {:error, changeset} ->
          send_json(conn, 422, %{error: "validation_failed", details: Accounts.errors_on(changeset)})
      end
    end)
  end

  put "/api/v1/profile/profile-picture" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{"profile_picture" => conn.body_params["profile_picture"]}

      case Accounts.update_profile_picture(user, attrs) do
        {:ok, updated_user} ->
          send_json(conn, 200, %{user: Accounts.user_response(updated_user)})

        {:error, changeset} ->
          send_json(conn, 422, %{error: "validation_failed", details: Accounts.errors_on(changeset)})
      end
    end)
  end

  get "/api/v1/home" do
    with_authenticated_user(conn, fn conn, user ->
      payload =
        %{home: %{}}
        |> maybe_put_missing_onboarding(user)

      send_json(conn, 200, payload)
    end)
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp bearer_token(conn) do
    with [auth_header | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         true <- String.starts_with?(auth_header, "Bearer ") do
      token = String.replace_prefix(auth_header, "Bearer ", "")

      if token == "" do
        {:error, :missing_bearer_token}
      else
        {:ok, token}
      end
    else
      _ -> {:error, :missing_bearer_token}
    end
  end

  defp with_authenticated_user(conn, success_callback) do
    case bearer_token(conn) do
      {:ok, token} ->
        with {:ok, claims} <- BluetteServer.Auth.verify_token(token),
             {:ok, user} <- Accounts.get_or_create_from_claims(claims) do
          success_callback.(conn, user)
        else
          {:error, reason} ->
            send_json(conn, 401, %{authenticated: false, error: to_string(reason)})
        end

      {:error, :missing_bearer_token} ->
        send_json(conn, 401, %{authenticated: false, error: "missing_bearer_token"})
    end
  end

  defp maybe_put_missing_onboarding(payload, user) do
    onboarding = Accounts.onboarding_payload(user)

    if onboarding.missing_fields == [] do
      payload
    else
      Map.put(payload, :onboarding, onboarding)
    end
  end

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end
end
