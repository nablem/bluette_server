defmodule BluetteServer.Accounts.Meeting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meetings" do
    field :status, :string
    field :scheduled_for, :utc_datetime
    field :place_name, :string
    field :place_latitude, :float
    field :place_longitude, :float
    field :survey_outcome, :string
    field :survey_resolved_at, :utc_datetime

    belongs_to :user_a, BluetteServer.Accounts.User
    belongs_to :user_b, BluetteServer.Accounts.User
    belongs_to :cancelled_by_user, BluetteServer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def create_changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [
      :user_a_id,
      :user_b_id,
      :status,
      :scheduled_for,
      :place_name,
      :place_latitude,
      :place_longitude,
      :survey_outcome,
      :survey_resolved_at,
      :cancelled_by_user_id
    ])
    |> validate_required([:user_a_id, :user_b_id, :status, :scheduled_for, :place_name])
    |> validate_inclusion(:status, ["upcoming", "happening", "due", "cancelled"],
      message: "must be upcoming, due, or cancelled"
    )
    |> validate_different_users()
  end

  def cancel_changeset(meeting, cancelled_by_user_id) do
    meeting
    |> cast(%{status: "cancelled", cancelled_by_user_id: cancelled_by_user_id}, [:status, :cancelled_by_user_id])
    |> validate_required([:status])
    |> validate_inclusion(:status, ["upcoming", "happening", "due", "cancelled"])
  end

  defp validate_different_users(changeset) do
    user_a_id = get_field(changeset, :user_a_id)
    user_b_id = get_field(changeset, :user_b_id)

    if user_a_id && user_b_id && user_a_id == user_b_id do
      add_error(changeset, :user_b_id, "must be different from user_a_id")
    else
      changeset
    end
  end
end
