defmodule BluetteServer.Accounts.Bar do
  use Ecto.Schema
  import Ecto.Changeset

  schema "bars" do
    field :google_place_id, :string
    field :name, :string
    field :address, :string
    field :locality, :string
    field :region_code, :string
    field :latitude, :float
    field :longitude, :float
    field :availability, :map
    field :google_maps_uri, :string
    field :timezone, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(bar, attrs) do
    bar
    |> cast(attrs, [
      :google_place_id,
      :name,
      :address,
      :locality,
      :region_code,
      :latitude,
      :longitude,
      :availability,
      :google_maps_uri,
      :timezone
    ])
    |> validate_required([:google_place_id, :name])
    |> unique_constraint(:google_place_id)
  end
end
