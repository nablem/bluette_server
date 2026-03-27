defmodule BluetteServer.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :firebase_uid, :string
    field :email, :string
    field :name, :string
    field :age, :integer
    field :gender, :string
    field :audio_bio, :string
    field :profile_picture, :string
    field :latitude, :float
    field :longitude, :float
    field :pref_min_age, :integer
    field :pref_max_age, :integer
    field :pref_max_distance_km, :integer
    field :pref_gender, :string
    field :visibility_rank, :integer

    timestamps(type: :utc_datetime)
  end

  def auth_changeset(user, attrs) do
    user
    |> cast(attrs, [:firebase_uid, :email, :visibility_rank])
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

  def gender_changeset(user, attrs) do
    user
    |> cast(attrs, [:gender])
    |> validate_required([:gender])
    |> validate_inclusion(:gender, ["male", "female", "other"],
      message: "must be male, female, or other"
    )
  end

  def location_changeset(user, attrs) do
    user
    |> cast(attrs, [:latitude, :longitude])
    |> validate_required([:latitude, :longitude])
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
  end

  def matching_preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:pref_min_age, :pref_max_age, :pref_max_distance_km, :pref_gender])
    |> validate_required([:pref_min_age, :pref_max_age, :pref_max_distance_km, :pref_gender])
    |> validate_number(:pref_min_age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)
    |> validate_number(:pref_max_age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)
    |> validate_number(:pref_max_distance_km, greater_than: 0)
    |> validate_inclusion(:pref_gender, ["male", "female", "everyone"],
      message: "must be male, female, or everyone"
    )
    |> validate_age_range()
  end

  def onboarding_completed?(%__MODULE__{} = user) do
    profile = [user.name, user.age, user.gender, user.audio_bio, user.profile_picture]
    prefs = [user.pref_min_age, user.pref_max_age, user.pref_max_distance_km, user.pref_gender]
    Enum.all?(profile ++ prefs, &(not is_nil(&1) and &1 != ""))
  end

  defp validate_age_range(changeset) do
    min = get_field(changeset, :pref_min_age)
    max = get_field(changeset, :pref_max_age)

    if min && max && min > max do
      add_error(changeset, :pref_max_age, "must be greater than or equal to min_age")
    else
      changeset
    end
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
