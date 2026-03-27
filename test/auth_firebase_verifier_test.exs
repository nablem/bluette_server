defmodule BluetteServer.Auth.FirebaseVerifierTest do
  use ExUnit.Case, async: true

  alias BluetteServer.Auth.FirebaseVerifier

  setup do
    previous_project_id = Application.get_env(:bluette_server, :firebase_project_id)
    previous_fetcher = Application.get_env(:bluette_server, :firebase_jwks_fetcher)

    Application.put_env(:bluette_server, :firebase_project_id, "bluette-test-project")
    Application.put_env(:bluette_server, :firebase_jwks_fetcher, BluetteServer.Auth.FirebaseVerifierTest.JwksFetcherMock)

    on_exit(fn ->
      restore_env(:firebase_project_id, previous_project_id)
      restore_env(:firebase_jwks_fetcher, previous_fetcher)
      Process.delete(:firebase_test_keys)
    end)

    :ok
  end

  test "verifies a valid Firebase token" do
    {token, claims} = build_token(email: "firebase_user@example.com")

    assert {:ok, auth_claims} = FirebaseVerifier.verify(token)

    assert auth_claims == %{
             uid: claims["sub"],
             email: "firebase_user@example.com",
             provider: "google.com",
             firebase: true
           }
  end

  test "rejects token with wrong audience" do
    {token, _claims} = build_token(aud: "another-project")

    assert {:error, :invalid_audience} = FirebaseVerifier.verify(token)
  end

  test "rejects expired token" do
    {token, _claims} = build_token(exp: System.system_time(:second) - 10)

    assert {:error, :token_expired} = FirebaseVerifier.verify(token)
  end

  test "returns config error when firebase project id is missing" do
    Application.delete_env(:bluette_server, :firebase_project_id)
    {token, _claims} = build_token()

    assert {:error, :firebase_project_id_not_configured} = FirebaseVerifier.verify(token)
  end

  defp build_token(opts \\ []) do
    now = System.system_time(:second)
    project_id = "bluette-test-project"

    private_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    kid = "test-kid"
    private_jwk_with_kid = JOSE.JWK.merge(private_jwk, %{"kid" => kid})

    {_meta, public_jwk_map} = private_jwk_with_kid |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    Process.put(:firebase_test_keys, [public_jwk_map])

    claims = %{
      "iss" => "https://securetoken.google.com/#{project_id}",
      "aud" => Keyword.get(opts, :aud, project_id),
      "sub" => Keyword.get(opts, :sub, "firebase_uid_123"),
      "email" => Keyword.get(opts, :email, "user@example.com"),
      "exp" => Keyword.get(opts, :exp, now + 3600),
      "iat" => Keyword.get(opts, :iat, now - 10),
      "firebase" => %{"sign_in_provider" => "google.com"}
    }

    jws = JOSE.JWS.from_map(%{"alg" => "RS256", "kid" => kid})

    token =
      private_jwk_with_kid
      |> JOSE.JWT.sign(jws, claims)
      |> JOSE.JWS.compact()
      |> elem(1)

    {token, claims}
  end

  defp restore_env(key, nil), do: Application.delete_env(:bluette_server, key)
  defp restore_env(key, value), do: Application.put_env(:bluette_server, key, value)
end

defmodule BluetteServer.Auth.FirebaseVerifierTest.JwksFetcherMock do
  @behaviour BluetteServer.Auth.FirebaseJwksFetcher

  @impl true
  def fetch_jwks(_url) do
    {:ok, Process.get(:firebase_test_keys, [])}
  end
end
