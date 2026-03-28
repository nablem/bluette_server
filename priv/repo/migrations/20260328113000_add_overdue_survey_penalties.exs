defmodule BluetteServer.Repo.Migrations.AddOverdueSurveyPenalties do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :user_a_survey_overdue_penalized_at, :utc_datetime
      add :user_b_survey_overdue_penalized_at, :utc_datetime
    end
  end
end
