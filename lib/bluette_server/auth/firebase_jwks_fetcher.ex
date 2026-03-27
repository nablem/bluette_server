defmodule BluetteServer.Auth.FirebaseJwksFetcher do
  @moduledoc false

  @callback fetch_jwks(String.t()) :: {:ok, list(map())} | {:error, atom()}
end
