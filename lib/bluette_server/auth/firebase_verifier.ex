defmodule BluetteServer.Auth.FirebaseVerifier do
  @moduledoc """
  Placeholder verifier for Firebase ID tokens.

  This module will be implemented with real signature and claims validation in
  a dedicated auth iteration.
  """

  @behaviour BluetteServer.Auth.Verifier

  @impl true
  def verify(_token), do: {:error, :firebase_not_implemented}
end
