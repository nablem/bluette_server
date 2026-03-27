defmodule BluetteServer.Repo.Migrations.AddGenderLocationAndMatchingPreferences do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :gender, :string
      add :latitude, :float
      add :longitude, :float
      add :pref_min_age, :integer
      add :pref_max_age, :integer
      add :pref_max_distance_km, :integer
      add :pref_gender, :string
    end
  end
end
