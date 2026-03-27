defmodule BluetteServer.Auth.FirebaseJwksFetcher.HTTP do
  @moduledoc false

  @behaviour BluetteServer.Auth.FirebaseJwksFetcher

  @impl true
  def fetch_jwks(url) when is_binary(url) do
    :inets.start()

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_http_version, 200, _reason_phrase}, _headers, body}} ->
        decode_jwks(body)

      {:ok, {{_http_version, status, _reason_phrase}, _headers, _body}} when status >= 400 ->
        {:error, :jwks_http_error}

      {:error, _reason} ->
        {:error, :jwks_request_failed}
    end
  end

  defp decode_jwks(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         %{"keys" => keys} when is_list(keys) <- decoded do
      {:ok, keys}
    else
      _ -> {:error, :invalid_jwks_response}
    end
  end
end
