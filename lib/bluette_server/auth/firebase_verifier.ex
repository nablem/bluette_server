defmodule BluetteServer.Auth.FirebaseVerifier do
  @moduledoc """
  Verifies Firebase ID tokens using Google Secure Token JWKS.
  """

  @behaviour BluetteServer.Auth.Verifier

  @jwks_url "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"

  @impl true
  def verify(token) when is_binary(token) do
    with {:ok, project_id} <- fetch_project_id(),
         {:ok, header} <- decode_header(token),
         {:ok, kid} <- fetch_kid(header),
         :ok <- validate_algorithm(header),
         {:ok, jwk_map} <- fetch_signing_key(kid),
         {:ok, claims} <- verify_signature(token, jwk_map),
         :ok <- validate_claims(claims, project_id),
         {:ok, auth_claims} <- to_auth_claims(claims) do
      {:ok, auth_claims}
    end
  end

  def verify(_token), do: {:error, :invalid_token}

  defp fetch_project_id do
    case Application.get_env(:bluette_server, :firebase_project_id) do
      project_id when is_binary(project_id) and project_id != "" -> {:ok, project_id}
      _ -> {:error, :firebase_project_id_not_configured}
    end
  end

  defp decode_header(token) do
    case String.split(token, ".") do
      [encoded_header, _payload, _signature] ->
        with {:ok, raw_header} <- Base.url_decode64(encoded_header, padding: false),
             {:ok, header} <- Jason.decode(raw_header) do
          {:ok, header}
        else
          _ -> {:error, :invalid_token_header}
        end

      _ ->
        {:error, :invalid_token}
    end
  end

  defp fetch_kid(%{"kid" => kid}) when is_binary(kid) and kid != "", do: {:ok, kid}
  defp fetch_kid(_header), do: {:error, :invalid_token_header}

  defp validate_algorithm(%{"alg" => "RS256"}), do: :ok
  defp validate_algorithm(_header), do: {:error, :invalid_token_algorithm}

  defp fetch_signing_key(kid) do
    fetcher = Application.get_env(:bluette_server, :firebase_jwks_fetcher, BluetteServer.Auth.FirebaseJwksFetcher.HTTP)
    url = Application.get_env(:bluette_server, :firebase_jwks_url, @jwks_url)

    with {:ok, keys} <- fetcher.fetch_jwks(url),
         {:ok, key} <- find_key(keys, kid) do
      {:ok, key}
    else
      {:error, :signing_key_not_found} -> {:error, :signing_key_not_found}
      _ -> {:error, :unable_to_fetch_signing_keys}
    end
  end

  defp find_key(keys, kid) when is_list(keys) do
    case Enum.find(keys, fn key -> key["kid"] == kid end) do
      nil -> {:error, :signing_key_not_found}
      key -> {:ok, key}
    end
  end

  defp verify_signature(token, jwk_map) do
    jwk = JOSE.JWK.from_map(jwk_map)

    case JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  defp validate_claims(claims, project_id) do
    expected_issuer = "https://securetoken.google.com/#{project_id}"
    now = System.system_time(:second)

    cond do
      claims["iss"] != expected_issuer ->
        {:error, :invalid_issuer}

      claims["aud"] != project_id ->
        {:error, :invalid_audience}

      not valid_subject?(claims["sub"]) ->
        {:error, :invalid_subject}

      not valid_exp?(claims["exp"], now) ->
        {:error, :token_expired}

      not valid_iat?(claims["iat"], now) ->
        {:error, :invalid_iat}

      true ->
        :ok
    end
  end

  defp valid_subject?(sub), do: is_binary(sub) and byte_size(sub) > 0

  defp valid_exp?(exp, now), do: is_integer(exp) and exp > now

  defp valid_iat?(iat, now), do: is_integer(iat) and iat <= now

  defp to_auth_claims(%{"sub" => uid, "email" => email} = claims)
       when is_binary(uid) and uid != "" and is_binary(email) and email != "" do
    sign_in_provider = get_in(claims, ["firebase", "sign_in_provider"])

    {:ok,
     %{
       uid: uid,
       email: email,
       provider: sign_in_provider || "google",
       firebase: true
     }}
  end

  defp to_auth_claims(_claims), do: {:error, :invalid_email}
end
