defmodule BluetteServer.Repo.Migrations.AddMeetingSurveys do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :survey_outcome, :string
      add :survey_resolved_at, :utc_datetime
    end

    create table(:meeting_surveys) do
      add :meeting_id, references(:meetings, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :attended, :boolean, null: false
      add :answered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meeting_surveys, [:meeting_id, :user_id])
    create index(:meeting_surveys, [:user_id, :answered_at])
  end
end
