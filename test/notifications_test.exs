defmodule BluetteServer.NotificationsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias BluetteServer.Accounts.Bar
  alias BluetteServer.Accounts.Meeting
  alias BluetteServer.Accounts.User
  alias BluetteServer.Notifications
  alias BluetteServer.Notifications.Notification
  alias BluetteServer.Repo
  alias BluetteServer.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Notification)
    Repo.delete_all(Meeting)
    Repo.delete_all(User)
    Repo.delete_all(Bar)

    :ok
  end

  test "reciprocal match creates notifications and stream events for both users" do
    insert_all_day_open_bar("notif_open_bar", "Notif Open Bar", 48.8671, 2.2688)

    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")

    :ok = Notifications.subscribe(user_a.id)
    :ok = Notifications.subscribe(user_b.id)

    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_b", "decision" => "like"}, "user_a", "a@example.com")

    _ =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_a", "decision" => "like"}, "user_b", "b@example.com")

    assert_receive {:notification, %{event_type: "match_created", payload: payload_a}}, 1_000
    assert payload_a[:meeting_id] || payload_a["meeting_id"]

    assert_receive {:notification, %{event_type: "match_created", payload: payload_b}}, 1_000
    assert payload_b[:meeting_id] || payload_b["meeting_id"]

    a_notifications = Notifications.list_user_notifications(user_a.id)
    b_notifications = Notifications.list_user_notifications(user_b.id)

    assert Enum.any?(a_notifications, &(&1.event_type == "match_created"))
    assert Enum.any?(b_notifications, &(&1.event_type == "match_created"))
  end

  test "home polling transitions meeting to happening and emits notification" do
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

    :ok = Notifications.subscribe(user_a.id)

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert response.status == 200

    assert_receive {:notification, %{event_type: "meeting_happening", payload: payload}}, 1_000
    assert (payload[:meeting_id] || payload["meeting_id"]) == meeting.id

    refreshed = Repo.get!(Meeting, meeting.id)
    assert refreshed.status == "happening"
  end

  test "home polling transitions old happening meeting to due and emits notification" do
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

    :ok = Notifications.subscribe(user_a.id)

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert response.status == 200

    assert_receive {:notification, %{event_type: "meeting_due", payload: payload}}, 1_000
    assert (payload[:meeting_id] || payload["meeting_id"]) == meeting.id

    refreshed = Repo.get!(Meeting, meeting.id)
    assert refreshed.status == "due"
  end

  test "cancel meeting emits cancellation notification including canceller uid" do
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

    :ok = Notifications.subscribe(user_b.id)

    response = authed_json(:post, "/api/v1/home/meeting/cancel", %{}, "user_a", "a@example.com")
    assert response.status == 200

    assert_receive {:notification, %{event_type: "meeting_cancelled", payload: payload}}, 1_000
    assert (payload[:cancelled_by_uid] || payload["cancelled_by_uid"]) == "user_a"
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
