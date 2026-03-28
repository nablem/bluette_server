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

  test "GET /api/v1/home keeps meeting mode when within 12h grace period" do
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
        scheduled_for: DateTime.add(now, -10 * 3600, :second),
        place_name: "Recent Meeting Place",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert response.status == 200

    body = Jason.decode!(response.resp_body)
    assert body["home"]["mode"] == "meeting"
    assert body["home"]["can_swipe"] == false

    refreshed = Repo.get!(Meeting, meeting.id)
    assert refreshed.status == "happening"
  end

  test "GET /api/v1/home marks past meeting as due and returns survey mode" do
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
        scheduled_for: DateTime.add(now, -13 * 3600, :second),
        place_name: "Past Meeting Place",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert response.status == 200

    body = Jason.decode!(response.resp_body)
    assert body["home"]["mode"] == "survey"
    assert body["home"]["can_swipe"] == false
    assert body["home"]["survey"]["meeting"]["id"] == meeting.id

    refreshed = Repo.get!(Meeting, meeting.id)
    assert refreshed.status == "due"
  end

  test "POST /api/v1/home/swipe pass does not create a meeting even with reciprocal like" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    # user_b likes user_a first
    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_a", "decision" => "like"}, "user_b", "b@example.com")

    # user_a passes on user_b — should not create a meeting
    resp =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_b", "decision" => "pass"}, "user_a", "a@example.com")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["swipe"]["match_created"] == false
    assert body["home"]["mode"] == "stack"
  end

  test "POST /api/v1/home/swipe is blocked during a happening meeting" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")
    create_completed_user("user_c", "c@example.com", "male", 31, "everyone")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _meeting} =
      %Meeting{}
      |> Meeting.create_changeset(%{
        user_a_id: user_a.id,
        user_b_id: user_b.id,
        status: "upcoming",
        scheduled_for: DateTime.add(now, -10 * 3600, :second),
        place_name: "Happening Bar",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    blocked =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_c", "decision" => "like"}, "user_a", "a@example.com")

    assert blocked.status == 409
    assert Jason.decode!(blocked.resp_body)["error"] == "meeting_in_progress"
  end

  test "POST /api/v1/home/meeting/cancel works during a happening meeting and lowers visibility rank" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _meeting} =
      %Meeting{}
      |> Meeting.create_changeset(%{
        user_a_id: user_a.id,
        user_b_id: user_b.id,
        status: "upcoming",
        scheduled_for: DateTime.add(now, -10 * 3600, :second),
        place_name: "Happening Bar",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    resp =
      authed_json(:post, "/api/v1/home/meeting/cancel", %{}, "user_a", "a@example.com")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["meeting"]["status"] == "cancelled"
    assert body["home"]["mode"] == "stack"
    assert body["home"]["can_swipe"] == true

    user_a_refreshed = Repo.get_by!(User, firebase_uid: "user_a")
    assert user_a_refreshed.visibility_rank == 80
  end

  test "POST /api/v1/home/meeting/cancel when no meeting exists returns 404" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")

    resp = authed_json(:post, "/api/v1/home/meeting/cancel", %{}, "user_a", "a@example.com")

    assert resp.status == 404
    assert Jason.decode!(resp.resp_body)["error"] == "no_upcoming_meeting"
  end

  test "GET /api/v1/home of other party after cancel also returns stack mode" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _meeting} =
      %Meeting{}
      |> Meeting.create_changeset(%{
        user_a_id: user_a.id,
        user_b_id: user_b.id,
        status: "upcoming",
        scheduled_for: DateTime.add(now, 3600, :second),
        place_name: "Future Bar",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    _ = authed_json(:post, "/api/v1/home/meeting/cancel", %{}, "user_a", "a@example.com")

    resp_b = authed(:get, "/api/v1/home", "user_b", "b@example.com")
    assert resp_b.status == 200
    body = Jason.decode!(resp_b.resp_body)
    assert body["home"]["mode"] == "stack"
    assert body["home"]["can_swipe"] == true
  end

  test "GET /api/v1/home transitions happening meeting to due after grace period" do
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
        status: "happening",
        scheduled_for: DateTime.add(now, -13 * 3600, :second),
        place_name: "Old Happening Bar",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    resp = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert resp.status == 200

    body = Jason.decode!(resp.resp_body)
    assert body["home"]["mode"] == "survey"
    assert body["home"]["can_swipe"] == false
    assert body["home"]["survey"]["meeting"]["id"] == meeting.id

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
