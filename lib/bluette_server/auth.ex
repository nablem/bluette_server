defmodule BluetteServer.Auth do
  @moduledoc """
  Authentication boundary for token verification.
  """

  @spec verify_token(String.t()) :: {:ok, map()} | {:error, atom()}
  def verify_token(token) when is_binary(token) do
    verifier().verify(token)
  end

  defp verifier do
    Application.get_env(:bluette_server, :auth_verifier, BluetteServer.Auth.MockVerifier)
  end
end
