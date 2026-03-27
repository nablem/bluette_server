defmodule Mix.Tasks.Bluette.SeedFakeProfiles do
  use Mix.Task

  @shortdoc "Seeds 30 fake Bluette profiles"

  @moduledoc """
  Populates the database with fake completed profiles.

      mix bluette.seed_fake_profiles
      mix bluette.seed_fake_profiles 50
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    count =
      case args do
        [value] -> String.to_integer(value)
        _ -> 30
      end

    inserted = BluetteServer.Accounts.seed_fake_profiles(count)
    Mix.shell().info("Seeded #{inserted} fake profiles")
  end
end
