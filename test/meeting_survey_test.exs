defmodule BluetteServer.MeetingSurveyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias BluetteServer.Accounts.Bar
  alias BluetteServer.Accounts.Meeting
  alias BluetteServer.Accounts.MeetingSurvey
  alias BluetteServer.Accounts.User
  alias BluetteServer.Notifications
  alias BluetteServer.Notifications.Notification
  alias BluetteServer.Repo
  alias BluetteServer.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Notification)
    Repo.delete_all(MeetingSurvey)
    Repo.delete_all(Meeting)
    Repo.delete_all(User)
    Repo.delete_all(Bar)

    :ok
  end

  test "GET /api/v1/home returns survey mode when due meeting is unanswered" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    meeting = create_due_meeting("user_a", "user_b")

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert response.status == 200

    body = Jason.decode!(response.resp_body)
    assert body["home"]["mode"] == "survey"
    assert body["home"]["can_swipe"] == false
    assert body["home"]["survey"]["meeting"]["id"] == meeting.id
    assert body["home"]["survey"]["meeting"]["with_user"]["uid"] == "user_b"
  end

  test "GET /api/v1/home returns stack when due survey is already answered by current user" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _meeting = create_due_meeting("user_a", "user_b")

    submit_response =
      authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_a", "a@example.com")

    assert submit_response.status == 200

    response = authed(:get, "/api/v1/home", "user_a", "a@example.com")
    assert response.status == 200

    body = Jason.decode!(response.resp_body)
    assert body["home"]["mode"] == "stack"
    assert body["home"]["can_swipe"] == true
  end

  test "POST /api/v1/home/meeting/survey returns 404 when no pending due survey exists" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")

    response =
      authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_a", "a@example.com")

    assert response.status == 404
    assert Jason.decode!(response.resp_body)["error"] == "no_due_meeting_survey"
  end

  test "POST /api/v1/home/meeting/survey validates attended as boolean" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _meeting = create_due_meeting("user_a", "user_b")

    invalid_string =
      authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => "yes"}, "user_a", "a@example.com")

    assert invalid_string.status == 422

    invalid_null =
      authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => nil}, "user_a", "a@example.com")

    assert invalid_null.status == 422

    invalid_missing =
      authed_json(:post, "/api/v1/home/meeting/survey", %{}, "user_a", "a@example.com")

    assert invalid_missing.status == 422
  end

  test "POST /api/v1/home/swipe is blocked with survey_pending while due survey is unanswered" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")
    create_completed_user("user_c", "c@example.com", "male", 31, "everyone")

    _meeting = create_due_meeting("user_a", "user_b")

    response =
      authed_json(:post, "/api/v1/home/swipe", %{"target_uid" => "user_c", "decision" => "like"}, "user_a", "a@example.com")

    assert response.status == 409
    assert Jason.decode!(response.resp_body)["error"] == "survey_pending"
  end

  test "both yes survey answers grant +5 rank to both users" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _meeting = create_due_meeting("user_a", "user_b")

    response_a =
      authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_a", "a@example.com")

    assert response_a.status == 200
    assert Jason.decode!(response_a.resp_body)["home"]["mode"] == "stack"

    response_b =
      authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_b", "b@example.com")

    assert response_b.status == 200

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")

    assert user_a.visibility_rank == 105
    assert user_b.visibility_rank == 105
  end

  test "both no survey answers remove 5 rank from both users" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _meeting = create_due_meeting("user_a", "user_b")

    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => false}, "user_a", "a@example.com")
    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => false}, "user_b", "b@example.com")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")

    assert user_a.visibility_rank == 95
    assert user_b.visibility_rank == 95
  end

  test "mixed survey answers do not change rank" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _meeting = create_due_meeting("user_a", "user_b")

    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_a", "a@example.com")
    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => false}, "user_b", "b@example.com")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")

    assert user_a.visibility_rank == 100
    assert user_b.visibility_rank == 100
  end

  test "after one user answers, other user still sees survey mode" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    _meeting = create_due_meeting("user_a", "user_b")

    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_a", "a@example.com")

    response_b = authed(:get, "/api/v1/home", "user_b", "b@example.com")
    assert response_b.status == 200

    body_b = Jason.decode!(response_b.resp_body)
    assert body_b["home"]["mode"] == "survey"
    assert body_b["home"]["can_swipe"] == false
  end

  test "both no ranking never drops below zero" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _ =
      Repo.update_all(
        from(u in User, where: u.id in ^[user_a.id, user_b.id]),
        set: [visibility_rank: 2, updated_at: now]
      )

    _meeting = create_due_meeting("user_a", "user_b")

    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => false}, "user_a", "a@example.com")
    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => false}, "user_b", "b@example.com")

    user_a_after = Repo.get_by!(User, firebase_uid: "user_a")
    user_b_after = Repo.get_by!(User, firebase_uid: "user_b")

    assert user_a_after.visibility_rank == 0
    assert user_b_after.visibility_rank == 0
  end

  test "meeting_survey_required and meeting_survey_resolved notifications are emitted" do
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

    assert_receive {:notification, %{event_type: "meeting_due", payload: payload_due}}, 1_000
    assert (payload_due[:meeting_id] || payload_due["meeting_id"]) == meeting.id

    assert_receive {:notification, %{event_type: "meeting_survey_required", payload: payload_required}}, 1_000
    assert (payload_required[:meeting_id] || payload_required["meeting_id"]) == meeting.id

    :ok = Notifications.subscribe(user_b.id)

    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_a", "a@example.com")
    _ = authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_b", "b@example.com")

    assert_receive {:notification, %{event_type: "meeting_survey_resolved", payload: payload_resolved}}, 1_000
    assert (payload_resolved[:survey_outcome] || payload_resolved["survey_outcome"]) == "both_yes"
    assert (payload_resolved[:rank_delta] || payload_resolved["rank_delta"]) == 5

    a_notifications = Notifications.list_user_notifications(user_a.id)
    b_notifications = Notifications.list_user_notifications(user_b.id)

    assert Enum.any?(a_notifications, &(&1.event_type == "meeting_survey_required"))
    assert Enum.any?(b_notifications, &(&1.event_type == "meeting_survey_required"))
    assert Enum.any?(a_notifications, &(&1.event_type == "meeting_survey_resolved"))
    assert Enum.any?(b_notifications, &(&1.event_type == "meeting_survey_resolved"))
  end

  test "concurrent survey submissions apply outcome once" do
    create_completed_user("user_a", "a@example.com", "female", 27, "everyone")
    create_completed_user("user_b", "b@example.com", "male", 29, "everyone")

    meeting = create_due_meeting("user_a", "user_b")

    task_a =
      Task.async(fn ->
        authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_a", "a@example.com")
      end)

    task_b =
      Task.async(fn ->
        authed_json(:post, "/api/v1/home/meeting/survey", %{"attended" => true}, "user_b", "b@example.com")
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task_a.pid)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task_b.pid)

    response_a = Task.await(task_a, 2_000)
    response_b = Task.await(task_b, 2_000)

    assert response_a.status == 200
    assert response_b.status == 200

    refreshed_meeting = Repo.get!(Meeting, meeting.id)
    assert refreshed_meeting.survey_outcome == "both_yes"
    assert refreshed_meeting.survey_resolved_at != nil

    surveys_count =
      from(s in MeetingSurvey,
        where: s.meeting_id == ^meeting.id,
        select: count(s.id)
      )
      |> Repo.one()

    assert surveys_count == 2

    user_a = Repo.get_by!(User, firebase_uid: "user_a")
    user_b = Repo.get_by!(User, firebase_uid: "user_b")

    assert user_a.visibility_rank == 105
    assert user_b.visibility_rank == 105

    a_notifications = Notifications.list_user_notifications(user_a.id)
    b_notifications = Notifications.list_user_notifications(user_b.id)

    assert Enum.count(a_notifications, &(&1.event_type == "meeting_survey_resolved")) == 1
    assert Enum.count(b_notifications, &(&1.event_type == "meeting_survey_resolved")) == 1
  end

  defp create_due_meeting(user_a_uid, user_b_uid) do
    user_a = Repo.get_by!(User, firebase_uid: user_a_uid)
    user_b = Repo.get_by!(User, firebase_uid: user_b_uid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, meeting} =
      %Meeting{}
      |> Meeting.create_changeset(%{
        user_a_id: user_a.id,
        user_b_id: user_b.id,
        status: "due",
        scheduled_for: DateTime.add(now, -13 * 3600, :second),
        place_name: "Past Meeting Place",
        place_latitude: 48.86,
        place_longitude: 2.34
      })
      |> Repo.insert()

    meeting
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
      conn(
        :put,
        "/api/v1/profile/matching-preferences",
        Jason.encode!(%{"min_age" => 18, "max_age" => 50, "max_distance_km" => 100, "preferred_gender" => pref_gender})
      )
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
