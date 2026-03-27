defmodule BluetteServer.HomeMatchingTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias BluetteServer.Accounts.User
  alias BluetteServer.Accounts.Bar
  alias BluetteServer.Accounts.Meeting
  alias BluetteServer.Repo
  alias BluetteServer.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Meeting)
    Repo.delete_all(User)
    Repo.delete_all(Bar)

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

  test "GET /api/v1/home excludes already-swiped profiles from stack" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_b", "decision" => "like"}, "user_a", "a@example.com")

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")

    assert response.status == 200
    body = Jason.decode!(response.resp_body)

    assert body["home"]["mode"] == "stack"
    assert body["home"]["profile"] == nil
  end

  test "POST /api/v1/home/swipe creates a meeting on reciprocal likes" do
    insert_all_day_open_bar("test_open_bar", "Open Test Bar", 48.8671, 2.2688)

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
    assert body["home"]["meeting"]["place"]["name"] == "Open Test Bar"
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
    insert_all_day_open_bar("test_open_bar_2", "Open Test Bar 2", 48.8671, 2.2688)

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

  test "GET /api/v1/home marks past meeting as due and returns stack mode" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, meeting} =
      %Meeting{}
      |> Meeting.create_changeset(%{
        user_a_id: user_a.id,
        user_b_id: user_b.id,
        status: "upcoming",
        scheduled_for: DateTime.add(now, -3600, :second),
        place_name: "Past Meeting Place",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert response.status == 200

    body = Jason.decode!(response.resp_body)
    assert body["home"]["mode"] == "stack"
    assert body["home"]["can_swipe"] == true

    refreshed = Repo.get!(Meeting, meeting.id)
    assert refreshed.status == "due"
  end

  defp insert_all_day_open_bar(google_place_id, name, latitude, longitude) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    availability =
      for day <- ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"],
          into: %{} do
        {day, %{"start" => "00:00", "end" => "23:59"}}
      end

    Repo.insert_all(Bar, [
      %{
        google_place_id: google_place_id,
        name: name,
        address: "1 Rue Test",
        locality: "Paris",
        region_code: "FR",
        latitude: latitude,
        longitude: longitude,
        availability: availability,
        google_maps_uri: "https://maps.google.com/",
        timezone: "Europe/Paris",
        inserted_at: now,
        updated_at: now
      }
    ])
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
