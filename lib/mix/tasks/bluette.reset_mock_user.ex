defmodule Mix.Tasks.Bluette.ResetMockUser do
  use Mix.Task

  @shortdoc "Clears onboarding details for the mock bearer user"

  @moduledoc """
  Clears the onboarding fields for the mock bearer user while keeping the user record.

      mix bluette.reset_mock_user
      mix bluette.reset_mock_user user_42
  """

  @default_uid "user_1"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    firebase_uid = List.first(args) || @default_uid

    case BluetteServer.Accounts.clear_user_details(firebase_uid) do
      {:ok, _user} ->
        Mix.shell().info("Cleared onboarding details for #{firebase_uid}")

      {:error, :user_not_found} ->
        Mix.raise("User not found for firebase_uid=#{firebase_uid}")
    end
  end
end
