defmodule BluetteServer.SettingsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias BluetteServer.Accounts
  alias BluetteServer.Accounts.User
  alias BluetteServer.Repo
  alias BluetteServer.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(User)

    _login =
      conn(:post, "/api/v1/auth/verify")
      |> put_req_header("authorization", "Bearer mock:user_1:user1@example.com")
      |> Router.call([])

    :ok
  end

  defp authed_json(method, path, payload) do
    conn(method, path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer mock:user_1:user1@example.com")
    |> Router.call([])
  end

  defp authed(method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer mock:user_1:user1@example.com")
    |> Router.call([])
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/v1/profile
  # ---------------------------------------------------------------------------

  test "DELETE /api/v1/profile removes user from database and returns 204" do
    response = authed(:delete, "/api/v1/profile")

    assert response.status == 204
    assert response.resp_body == ""
    assert Repo.get_by(User, firebase_uid: "user_1") == nil
  end

  test "DELETE /api/v1/profile requires authentication" do
    response = conn(:delete, "/api/v1/profile") |> Router.call([])

    assert response.status == 401
  end

  # ---------------------------------------------------------------------------
  # PUT /api/v1/profile/gender
  # ---------------------------------------------------------------------------

  test "PUT /api/v1/profile/gender accepts male/female/other" do
    for gender <- ["male", "female", "other"] do
      response = authed_json(:put, "/api/v1/profile/gender", %{"gender" => gender})

      assert response.status == 200
      assert Jason.decode!(response.resp_body)["user"]["gender"] == gender
    end
  end

  test "PUT /api/v1/profile/gender rejects invalid value" do
    response = authed_json(:put, "/api/v1/profile/gender", %{"gender" => "alien"})

    assert response.status == 422

    assert Jason.decode!(response.resp_body) == %{
             "error" => "validation_failed",
             "details" => %{"gender" => ["must be male, female, or other"]}
           }
  end

  test "PUT /api/v1/profile/gender does not include onboarding in response" do
    response = authed_json(:put, "/api/v1/profile/gender", %{"gender" => "male"})

    assert response.status == 200
    refute Map.has_key?(Jason.decode!(response.resp_body), "onboarding")
  end

  # ---------------------------------------------------------------------------
  # PUT /api/v1/profile/location
  # ---------------------------------------------------------------------------

  test "PUT /api/v1/profile/location persists latitude and longitude" do
    response =
      authed_json(:put, "/api/v1/profile/location", %{"latitude" => 48.8566, "longitude" => 2.3522})

    assert response.status == 200
    user_payload = Jason.decode!(response.resp_body)["user"]
    assert user_payload["latitude"] == 48.8566
    assert user_payload["longitude"] == 2.3522
  end

  test "PUT /api/v1/profile/location rejects out-of-range coordinates" do
    response =
      authed_json(:put, "/api/v1/profile/location", %{"latitude" => 999.0, "longitude" => 2.3522})

    assert response.status == 422

    assert Jason.decode!(response.resp_body)["details"]["latitude"] != []
  end

  test "PUT /api/v1/profile/location does not include onboarding in response" do
    response =
      authed_json(:put, "/api/v1/profile/location", %{"latitude" => 48.8566, "longitude" => 2.3522})

    assert response.status == 200
    refute Map.has_key?(Jason.decode!(response.resp_body), "onboarding")
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/profile
  # ---------------------------------------------------------------------------

  test "GET /api/v1/profile returns full user and preferences" do
    response = authed(:get, "/api/v1/profile")

    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert Map.has_key?(body, "user")
    assert Map.has_key?(body, "preferences")
    assert body["user"]["uid"] == "user_1"
    assert body["preferences"]["min_age"] == nil
  end

  # ---------------------------------------------------------------------------
  # PUT /api/v1/profile/matching-preferences
  # ---------------------------------------------------------------------------

  test "PUT /api/v1/profile/matching-preferences saves and returns preferences" do
    response =
      authed_json(:put, "/api/v1/profile/matching-preferences", %{
        "min_age" => 20,
        "max_age" => 35,
        "max_distance_km" => 50,
        "preferred_gender" => "everyone"
      })

    assert response.status == 200

    assert Jason.decode!(response.resp_body) == %{
             "preferences" => %{
               "min_age" => 20,
               "max_age" => 35,
               "max_distance_km" => 50,
               "preferred_gender" => "everyone"
             }
           }
  end

  test "PUT /api/v1/profile/matching-preferences rejects min_age > max_age" do
    response =
      authed_json(:put, "/api/v1/profile/matching-preferences", %{
        "min_age" => 40,
        "max_age" => 30,
        "max_distance_km" => 50,
        "preferred_gender" => "female"
      })

    assert response.status == 422

    assert Jason.decode!(response.resp_body)["details"]["pref_max_age"] == [
             "must be greater than or equal to min_age"
           ]
  end

  test "PUT /api/v1/profile/matching-preferences rejects invalid preferred_gender" do
    response =
      authed_json(:put, "/api/v1/profile/matching-preferences", %{
        "min_age" => 20,
        "max_age" => 35,
        "max_distance_km" => 50,
        "preferred_gender" => "other"
      })

    assert response.status == 422

    assert Jason.decode!(response.resp_body)["details"]["pref_gender"] == [
             "must be male, female, or everyone"
           ]
  end

  test "PUT /api/v1/profile/matching-preferences rejects zero max_distance_km" do
    response =
      authed_json(:put, "/api/v1/profile/matching-preferences", %{
        "min_age" => 20,
        "max_age" => 35,
        "max_distance_km" => 0,
        "preferred_gender" => "everyone"
      })

    assert response.status == 422
    assert Jason.decode!(response.resp_body)["details"]["pref_max_distance_km"] != []
  end

  test "PUT /api/v1/profile/matching-preferences rejects age under 18" do
    response =
      authed_json(:put, "/api/v1/profile/matching-preferences", %{
        "min_age" => 16,
        "max_age" => 35,
        "max_distance_km" => 50,
        "preferred_gender" => "everyone"
      })

    assert response.status == 422
    assert Jason.decode!(response.resp_body)["details"]["pref_min_age"] != []
  end

  # ---------------------------------------------------------------------------
  # Accounts.delete_user/1
  # ---------------------------------------------------------------------------

  test "delete_user removes the record entirely" do
    user = Repo.get_by(User, firebase_uid: "user_1")
    assert {:ok, _} = Accounts.delete_user(user)
    assert Repo.get_by(User, firebase_uid: "user_1") == nil
  end
end
