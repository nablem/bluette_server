defmodule BluetteServer.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :firebase_uid, :string
    field :email, :string
    field :name, :string
    field :age, :integer
    field :audio_bio, :string
    field :profile_picture, :string

    timestamps(type: :utc_datetime)
  end

  def auth_changeset(user, attrs) do
    user
    |> cast(attrs, [:firebase_uid, :email])
    |> validate_required([:firebase_uid, :email])
    |> unique_constraint(:firebase_uid)
  end

  def name_changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
  end

  def age_changeset(user, attrs) do
    user
    |> cast(attrs, [:age])
    |> validate_required([:age])
    |> validate_number(:age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)
  end

  def audio_bio_changeset(user, attrs) do
    user
    |> cast(attrs, [:audio_bio])
    |> validate_required([:audio_bio])
    |> validate_length(:audio_bio, min: 1, max: 1000)
    |> validate_url(:audio_bio)
  end

  def profile_picture_changeset(user, attrs) do
    user
    |> cast(attrs, [:profile_picture])
    |> validate_required([:profile_picture])
    |> validate_length(:profile_picture, min: 1, max: 1000)
    |> validate_url(:profile_picture)
  end

  def onboarding_completed?(%__MODULE__{} = user) do
    required = [user.name, user.age, user.audio_bio, user.profile_picture]
    Enum.all?(required, &(not is_nil(&1) and &1 != ""))
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid http or https URL"}]
      end
    end)
  end
end
