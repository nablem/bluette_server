defmodule BluetteServer.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias BluetteServer.Accounts.User
  alias BluetteServer.Repo
  alias BluetteServer.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(User)
    :ok
  end

  test "GET /health returns ok" do
    conn = conn(:get, "/health") |> Router.call([])

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok", "service" => "bluette_server"}
  end

  test "POST /api/v1/auth/verify upserts user and returns onboarding missing fields" do
    conn =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_1:user1@example.com")
      |> Router.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "authenticated" => true,
             "user" => %{
               "age" => nil,
               "audio_bio" => nil,
               "email" => "user1@example.com",
               "gender" => nil,
               "latitude" => nil,
               "longitude" => nil,
               "name" => nil,
               "profile_picture" => nil,
               "uid" => "user_1"
             }
           }
  end

  test "POST /api/v1/auth/verify returns unauthorized when header is missing" do
    conn = conn(:post, "/api/v1/auth/verify") |> Router.call([])

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"authenticated" => false, "error" => "missing_bearer_token"}
  end

  test "POST /api/v1/auth/verify returns unauthorized for invalid token" do
    conn =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer invalid-token")
      |> Router.call([])

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"authenticated" => false, "error" => "invalid_token"}
  end

  test "profile detail endpoints update fields without onboarding payload" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_2:user2@example.com")
      |> Router.call([])

    update_name =
      authed_json_conn(:put, "/api/v1/profile/name", %{"name" => "Nabil"})
      |> Router.call([])

    assert update_name.status == 200
    assert Jason.decode!(update_name.resp_body) == %{
             "user" => %{
               "age" => nil,
               "audio_bio" => nil,
               "email" => "user2@example.com",
               "gender" => nil,
               "latitude" => nil,
               "longitude" => nil,
               "name" => "Nabil",
               "profile_picture" => nil,
               "uid" => "user_2"
             }
           }

    update_age =
      authed_json_conn(:put, "/api/v1/profile/age", %{"age" => 27})
      |> Router.call([])

    assert update_age.status == 200
    refute Map.has_key?(Jason.decode!(update_age.resp_body), "onboarding")

    update_audio_bio =
      authed_json_conn(:put, "/api/v1/profile/audio-bio", %{"audio_bio" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/audio1.m4a"})
      |> Router.call([])

    assert update_audio_bio.status == 200
    refute Map.has_key?(Jason.decode!(update_audio_bio.resp_body), "onboarding")

    update_profile_picture =
      authed_json_conn(:put, "/api/v1/profile/profile-picture", %{"profile_picture" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/selfie1.jpg"})
      |> Router.call([])

    assert update_profile_picture.status == 200
    refute Map.has_key?(Jason.decode!(update_profile_picture.resp_body), "onboarding")
  end

  test "profile age validates required fields" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_3:user3@example.com")
      |> Router.call([])

    response =
      conn(:put, "/api/v1/profile/age", Jason.encode!(%{"age" => 17}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_3:user3@example.com")
      |> Router.call([])

    assert response.status == 422

    assert Jason.decode!(response.resp_body) == %{
             "error" => "validation_failed",
             "details" => %{"age" => ["must be greater than or equal to 18"]}
           }
  end

  test "profile audio bio requires a valid URL" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_5:user5@example.com")
      |> Router.call([])

    response =
      conn(:put, "/api/v1/profile/audio-bio", Jason.encode!(%{"audio_bio" => "audio://bio"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_5:user5@example.com")
      |> Router.call([])

    assert response.status == 422

    assert Jason.decode!(response.resp_body) == %{
             "error" => "validation_failed",
             "details" => %{"audio_bio" => ["must be a valid http or https URL"]}
           }
  end

  test "GET /api/v1/home returns empty home payload" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_4:user4@example.com")
      |> Router.call([])

    response =
      conn(:get, "/api/v1/home")
      |> put_req_header("authorization", "Bearer mock:user_4:user4@example.com")
      |> Router.call([])

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{
             "home" => %{},
             "onboarding" => %{
               "completed" => false,
               "missing_fields" => [
                 "name",
                 "age",
                 "gender",
                 "audio_bio",
                 "profile_picture",
                 "pref_min_age",
                 "pref_max_age",
                 "pref_max_distance_km",
                 "pref_gender"
               ]
             }
           }
  end

  test "GET /api/v1/home omits onboarding when completed" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _name =
      conn(:put, "/api/v1/profile/name", Jason.encode!(%{"name" => "Jane"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _age =
      conn(:put, "/api/v1/profile/age", Jason.encode!(%{"age" => 30}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _gender =
      conn(:put, "/api/v1/profile/gender", Jason.encode!(%{"gender" => "female"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _audio =
      conn(:put, "/api/v1/profile/audio-bio", Jason.encode!(%{"audio_bio" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/audio6.m4a"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _picture =
      conn(:put, "/api/v1/profile/profile-picture", Jason.encode!(%{"profile_picture" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/selfie6.jpg"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _prefs =
      conn(:put, "/api/v1/profile/matching-preferences", Jason.encode!(%{"min_age" => 20, "max_age" => 40, "max_distance_km" => 50, "preferred_gender" => "everyone"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    response =
      conn(:get, "/api/v1/home")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"home" => %{}}
  end

  defp authed_json_conn(method, path, payload) do
    conn(method, path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer mock:user_2:user2@example.com")
  end
end
