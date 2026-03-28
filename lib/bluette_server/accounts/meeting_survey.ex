defmodule BluetteServer.Accounts.MeetingSurvey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meeting_surveys" do
    field :attended, :boolean
    field :answered_at, :utc_datetime

    belongs_to :meeting, BluetteServer.Accounts.Meeting
    belongs_to :user, BluetteServer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def create_changeset(meeting_survey, attrs) do
    meeting_survey
    |> cast(attrs, [:meeting_id, :user_id, :attended, :answered_at])
    |> validate_required([:meeting_id, :user_id, :attended, :answered_at])
    |> unique_constraint([:meeting_id, :user_id])
  end
end
