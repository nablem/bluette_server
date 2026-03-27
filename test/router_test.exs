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
               "name" => nil,
               "profile_picture" => nil,
               "uid" => "user_1"
             },
             "onboarding" => %{
               "completed" => false,
               "missing_fields" => ["name", "age", "audio_bio", "profile_picture"]
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

  test "onboarding step endpoints complete profile progressively" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_2:user2@example.com")
      |> Router.call([])

    step1 =
      authed_json_conn(:put, "/api/v1/onboarding/step-1", %{"name" => "Nabil", "age" => 27})
      |> Router.call([])

    assert step1.status == 200

    assert Jason.decode!(step1.resp_body)["onboarding"] == %{
             "completed" => false,
             "missing_fields" => ["audio_bio", "profile_picture"]
           }

    step2 =
      authed_json_conn(:put, "/api/v1/onboarding/step-2", %{"audio_bio" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/audio1.m4a"})
      |> Router.call([])

    assert step2.status == 200

    assert Jason.decode!(step2.resp_body)["onboarding"] == %{
             "completed" => false,
             "missing_fields" => ["profile_picture"]
           }

    step3 =
      authed_json_conn(:put, "/api/v1/onboarding/step-3", %{"profile_picture" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/selfie1.jpg"})
      |> Router.call([])

    assert step3.status == 200
    assert Jason.decode!(step3.resp_body)["onboarding"] == %{"completed" => true, "missing_fields" => []}
  end

  test "step 1 validates required fields" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_3:user3@example.com")
      |> Router.call([])

    response =
      authed_json_conn(:put, "/api/v1/onboarding/step-1", %{"age" => 17})
      |> Router.call([])

    assert response.status == 422

    assert Jason.decode!(response.resp_body) == %{
             "error" => "validation_failed",
             "details" => %{
               "age" => ["must be greater than or equal to 18"],
               "name" => ["can't be blank"]
             }
           }
  end

  test "step 2 requires a valid URL" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_5:user5@example.com")
      |> Router.call([])

    response =
      conn(:put, "/api/v1/onboarding/step-2", Jason.encode!(%{"audio_bio" => "audio://bio"}))
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
               "missing_fields" => ["name", "age", "audio_bio", "profile_picture"]
             }
           }
  end

  test "GET /api/v1/home omits onboarding when completed" do
    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _step1 =
      conn(:put, "/api/v1/onboarding/step-1", Jason.encode!(%{"name" => "Jane", "age" => 30}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _step2 =
      conn(:put, "/api/v1/onboarding/step-2", Jason.encode!(%{"audio_bio" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/audio6.m4a"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer mock:user_6:user6@example.com")
      |> Router.call([])

    _step3 =
      conn(:put, "/api/v1/onboarding/step-3", Jason.encode!(%{"profile_picture" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/selfie6.jpg"}))
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
