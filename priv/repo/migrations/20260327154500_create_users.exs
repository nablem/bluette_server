defmodule BluetteServer.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :firebase_uid, :string, null: false
      add :email, :string, null: false
      add :name, :string
      add :age, :integer
      add :audio_bio, :text
      add :profile_picture, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:firebase_uid])
  end
end
