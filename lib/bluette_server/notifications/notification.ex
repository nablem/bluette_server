defmodule BluetteServer.Notifications.Notification do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notifications" do
    field :event_type, :string
    field :payload, :map, default: %{}
    field :read_at, :utc_datetime

    belongs_to :user, BluetteServer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def create_changeset(notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :event_type, :payload, :read_at])
    |> validate_required([:user_id, :event_type, :payload])
  end
end
