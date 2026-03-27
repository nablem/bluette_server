defmodule BluetteServer.Accounts.Swipe do
  use Ecto.Schema
  import Ecto.Changeset

  schema "swipes" do
    field :decision, :string

    belongs_to :swiper_user, BluetteServer.Accounts.User
    belongs_to :swiped_user, BluetteServer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(swipe, attrs) do
    swipe
    |> cast(attrs, [:swiper_user_id, :swiped_user_id, :decision])
    |> validate_required([:swiper_user_id, :swiped_user_id, :decision])
    |> validate_inclusion(:decision, ["like", "pass"], message: "must be like or pass")
    |> unique_constraint([:swiper_user_id, :swiped_user_id])
  end
end
