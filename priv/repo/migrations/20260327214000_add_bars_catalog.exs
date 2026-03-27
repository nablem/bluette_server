defmodule BluetteServer.Repo.Migrations.AddBarsCatalog do
  use Ecto.Migration

  def change do
    create table(:bars) do
      add :google_place_id, :string, null: false
      add :name, :string, null: false
      add :address, :string
      add :locality, :string
      add :region_code, :string
      add :latitude, :float
      add :longitude, :float
      add :availability, :map
      add :google_maps_uri, :string
      add :timezone, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bars, [:google_place_id])
  end
end
