defmodule BluetteServer.HomeMatchingTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias BluetteServer.Accounts.User
  alias BluetteServer.Repo
  alias BluetteServer.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(User)

    :ok
  end

  test "GET /api/v1/home returns next stack profile when available" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")

    assert response.status == 200
    body = Jason.decode!(response.resp_body)

    assert body["home"]["mode"] == "stack"
    assert body["home"]["can_swipe"] == true
    assert body["home"]["profile"]["uid"] == "user_b"
  end

  test "POST /api/v1/home/swipe creates a meeting on reciprocal likes" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    first_swipe =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_b", "decision" => "like"}, "user_a", "a@example.com")

    assert first_swipe.status == 200
    assert Jason.decode!(first_swipe.resp_body)["swipe"]["match_created"] == false

    reciprocal_swipe =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_a", "decision" => "like"}, "user_b", "b@example.com")

    assert reciprocal_swipe.status == 200
    body = Jason.decode!(reciprocal_swipe.resp_body)

    assert body["swipe"]["match_created"] == true
    assert body["home"]["mode"] == "meeting"
    assert body["home"]["can_swipe"] == false
    assert body["home"]["meeting"]["with_user"]["uid"] == "user_a"
  end

  test "POST /api/v1/home/meeting/cancel cancels meeting and restores stack mode" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_b", "decision" => "like"}, "user_a", "a@example.com")

    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_a", "decision" => "like"}, "user_b", "b@example.com")

    cancel_response =
      authed_json(:post, "/api/v1/home/meeting/cancel", %{}, "user_a", "a@example.com")

    assert cancel_response.status == 200
    body = Jason.decode!(cancel_response.resp_body)
    assert body["meeting"]["status"] == "cancelled"
    assert body["home"]["mode"] == "stack"
    assert body["home"]["can_swipe"] == true
  end

  test "POST /api/v1/home/swipe rejects swipes while meeting is upcoming" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_b", "decision" => "like"}, "user_a", "a@example.com")

    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_a", "decision" => "like"}, "user_b", "b@example.com")

    blocked_swipe =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_b", "decision" => "pass"}, "user_a", "a@example.com")

    assert blocked_swipe.status == 409
    assert Jason.decode!(blocked_swipe.resp_body)["error"] == "meeting_in_progress"
  end

  defp create_completed_user(uid, email, gender, age, pref_gender) do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    _name =
      conn(:put, "/api/v1/profile/name", Jason.encode!(%{"name" => "Name #{uid}"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    _age =
      conn(:put, "/api/v1/profile/age", Jason.encode!(%{"age" => age}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    _gender =
      conn(:put, "/api/v1/profile/gender", Jason.encode!(%{"gender" => gender}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    _audio =
      conn(:put, "/api/v1/profile/audio-bio", Jason.encode!(%{"audio_bio" => "https://example.com/audio/#{uid}.mp3"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    _picture =
      conn(:put, "/api/v1/profile/profile-picture", Jason.encode!(%{"profile_picture" => "https://example.com/picture/#{uid}.jpg"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    _prefs =
      conn(:put, "/api/v1/profile/matching-preferences", Jason.encode!(%{"min_age" => 18, "max_age" => 50, "max_distance_km" => 100, "preferred_gender" => pref_gender}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    _location =
      conn(:put, "/api/v1/profile/location", Jason.encode!(%{"latitude" => 48.867178137901746, "longitude" => 2.2688445113445654}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
      |> Router.call([])

    :ok
  end

  defp authed_json(method, path, payload, uid, email) do
    conn(method, path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
    |> Router.call([])
  end

  defp authed(method, path, uid, email) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer mock:#{uid}:#{email}")
    |> Router.call([])
  end
end
