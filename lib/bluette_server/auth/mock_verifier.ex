defmodule BluetteServer.Auth.MockVerifier do
  @moduledoc """
  Development verifier for local iteration without external Firebase calls.

  Supported token format:
    mock:<uid>:<email>
  """

  @behaviour BluetteServer.Auth.Verifier

  @impl true
  def verify("mock:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [uid, email] when uid != "" and email != "" ->
        {:ok,
         %{
           uid: uid,
           email: email,
           provider: "google",
           mock: true
         }}

      _ ->
        {:error, :invalid_token_format}
    end
  end

  def verify(_token), do: {:error, :invalid_token}
end
