defmodule Mix.Tasks.Bluette.ImportBars do
  use Mix.Task

  @shortdoc "Imports bars from a JSON file"

  @moduledoc """
  Imports bars catalog from JSON.

      mix bluette.import_bars
      mix bluette.import_bars bars.json
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    path = import_path(args)

    case BluetteServer.Accounts.import_bars_from_json(path) do
      {:ok, count} ->
        Mix.shell().info("Imported #{count} bars from #{path}")

      {:error, reason} ->
        Mix.raise("Failed to import bars: #{inspect(reason)}")
    end
  end

  defp import_path([value]), do: value

  defp import_path(_args) do
    if File.exists?("bars.json") do
      "bars.json"
    else
      Mix.raise(
        "No bars JSON found. Provide a path: mix bluette.import_bars <file>. " <>
          "Looked for bars.json in project root."
      )
    end
  end
end
