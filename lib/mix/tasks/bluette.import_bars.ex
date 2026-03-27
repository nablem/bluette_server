defmodule Mix.Tasks.Bluette.ImportBars do
  use Mix.Task

  @shortdoc "Imports bars from a JSON file"

  @moduledoc """
  Imports bars catalog from JSON.

      mix bluette.import_bars
      mix bluette.import_bars bars_Paris_1st_arrondissement.json
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    path =
      case args do
        [value] -> value
        _ -> "bars_Paris_1st_arrondissement.json"
      end

    case BluetteServer.Accounts.import_bars_from_json(path) do
      {:ok, count} ->
        Mix.shell().info("Imported #{count} bars from #{path}")

      {:error, reason} ->
        Mix.raise("Failed to import bars: #{inspect(reason)}")
    end
  end
end
