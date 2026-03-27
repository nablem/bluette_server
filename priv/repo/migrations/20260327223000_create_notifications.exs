defmodule BluetteServer.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id, :inserted_at])
    create index(:notifications, [:user_id, :read_at])
  end
end
