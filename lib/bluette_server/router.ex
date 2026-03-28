defmodule BluetteServer.Router do
  use Plug.Router

  alias BluetteServer.Accounts
  alias BluetteServer.Notifications
  alias BluetteServer.Notifications.Stream

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

  delete "/api/v1/profile" do
    with_authenticated_user(conn, fn conn, user ->
      case Accounts.delete_user(user) do
        {:ok, _} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(204, "")

        {:error, reason} ->
          send_json(conn, 500, %{error: to_string(reason)})
      end
    end)
  end

  put "/api/v1/profile/gender" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{"gender" => conn.body_params["gender"]}

      case Accounts.update_gender(user, attrs) do
        {:ok, updated_user} ->
          send_json(conn, 200, %{user: Accounts.user_response(updated_user)})

        {:error, changeset} ->
          send_json(conn, 422, %{error: "validation_failed", details: Accounts.errors_on(changeset)})
      end
    end)
  end

  put "/api/v1/profile/location" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{
        "latitude" => conn.body_params["latitude"],
        "longitude" => conn.body_params["longitude"]
      }

      case Accounts.update_location(user, attrs) do
        {:ok, updated_user} ->
          send_json(conn, 200, %{user: Accounts.user_response(updated_user)})

        {:error, changeset} ->
          send_json(conn, 422, %{error: "validation_failed", details: Accounts.errors_on(changeset)})
      end
    end)
  end

  get "/api/v1/profile" do
    with_authenticated_user(conn, fn conn, user ->
      send_json(conn, 200, %{
        user: Accounts.user_response(user),
        preferences: Accounts.preferences_response(user)
      })
    end)
  end

  put "/api/v1/profile/matching-preferences" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{
        "pref_min_age" => conn.body_params["min_age"],
        "pref_max_age" => conn.body_params["max_age"],
        "pref_max_distance_km" => conn.body_params["max_distance_km"],
        "pref_gender" => conn.body_params["preferred_gender"]
      }

      case Accounts.update_matching_preferences(user, attrs) do
        {:ok, updated_user} ->
          send_json(conn, 200, %{preferences: Accounts.preferences_response(updated_user)})

        {:error, changeset} ->
          send_json(conn, 422, %{error: "validation_failed", details: Accounts.errors_on(changeset)})
      end
    end)
  end

  post "/api/v1/home/swipe" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{
        "target_uid" => conn.body_params["target_uid"],
        "decision" => conn.body_params["decision"]
      }

      case Accounts.swipe_profile(user, attrs) do
        {:ok, swipe_result} ->
          send_json(conn, 200, %{swipe: swipe_result, home: Accounts.home_payload(user)})

        {:error, :validation_failed} ->
          send_json(conn, 422, %{error: "validation_failed", details: %{target_uid: ["is required"]}})

        {:error, :invalid_swipe_decision} ->
          send_json(conn, 422, %{error: "validation_failed", details: %{decision: ["must be like or pass"]}})

        {:error, :survey_pending} ->
          send_json(conn, 409, %{error: "survey_pending"})

        {:error, reason} ->
          send_json(conn, 409, %{error: to_string(reason)})
      end
    end)
  end

  post "/api/v1/home/meeting/cancel" do
    with_authenticated_user(conn, fn conn, user ->
      case Accounts.cancel_upcoming_meeting(user) do
        {:ok, meeting} ->
          send_json(conn, 200, %{meeting: %{status: meeting.status}, home: Accounts.home_payload(user)})

        {:error, :no_upcoming_meeting} ->
          send_json(conn, 404, %{error: "no_upcoming_meeting"})

        {:error, reason} ->
          send_json(conn, 409, %{error: to_string(reason)})
      end
    end)
  end

  post "/api/v1/home/meeting/survey" do
    with_authenticated_user(conn, fn conn, user ->
      attrs = %{"attended" => conn.body_params["attended"]}

      case Accounts.submit_meeting_survey(user, attrs) do
        {:ok, _survey} ->
          send_json(conn, 200, %{home: Accounts.home_payload(user)})

        {:error, :invalid_survey_attended} ->
          send_json(conn, 422, %{error: "validation_failed", details: %{attended: ["must be true or false"]}})

        {:error, :no_due_meeting_survey} ->
          send_json(conn, 404, %{error: "no_due_meeting_survey"})

        {:error, reason} ->
          send_json(conn, 409, %{error: to_string(reason)})
      end
    end)
  end

  get "/api/v1/notifications" do
    with_authenticated_user(conn, fn conn, user ->
      limit = parse_integer(conn.query_params["limit"])
      after_id = parse_integer(conn.query_params["after_id"])

      notifications =
        Notifications.list_user_notifications(user.id,
          limit: limit || 50,
          after_id: after_id
        )

      send_json(conn, 200, %{notifications: notifications, unread_count: Notifications.unread_count(user.id)})
    end)
  end

  post "/api/v1/notifications/read" do
    with_authenticated_user(conn, fn conn, user ->
      ids = conn.body_params["ids"]

      updated =
        case ids do
          list when is_list(list) ->
            parsed_ids = Enum.map(list, &parse_integer/1) |> Enum.filter(&is_integer/1)
            Notifications.mark_as_read(user.id, parsed_ids)

          _ ->
            Notifications.mark_as_read(user.id, :all)
        end

      send_json(conn, 200, %{updated: updated, unread_count: Notifications.unread_count(user.id)})
    end)
  end

  get "/api/v1/notifications/stream" do
    with_authenticated_user(conn, fn conn, user ->
      Stream.stream(conn, user.id)
    end)
  end

  get "/api/v1/home" do
    with_authenticated_user(conn, fn conn, user ->
      payload =
        %{home: Accounts.home_payload(user)}
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

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
