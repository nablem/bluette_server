defmodule BluetteServer.Auth.Verifier do
  @moduledoc """
  Behaviour for token verifier implementations.
  """

  @callback verify(String.t()) :: {:ok, map()} | {:error, atom()}
end
