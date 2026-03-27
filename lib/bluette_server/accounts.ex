defmodule BluetteServer.Accounts do
  import Ecto.Changeset
  import Ecto.Query

  alias BluetteServer.Accounts.User
  alias BluetteServer.Repo

  @profile_picture_url "https://dessindigo.com/storage/images/posts/bob-eponge/dessin-bob-eponge.webp"
  @audio_bio_url "https://upload.wikimedia.org/wikipedia/commons/1/1f/Fundaci%C3%B3n_Joaqu%C3%ADn_D%C3%ADaz_-_ATO_00446_13_-_Rosario_de_Las_quince_rosas_de_Mar%C3%ADa.ogg"
  @seed_latitude 48.867178137901746
  @seed_longitude 2.2688445113445654
  @seed_genders ["male", "female", "other"]
  @seed_preferred_genders ["male", "female", "everyone"]
  @seed_max_distance_km [5, 10, 25, 50, 100]
  @first_names [
    "Alice",
    "Amine",
    "Aya",
    "Camille",
    "Chloe",
    "Elias",
    "Emma",
    "Hugo",
    "Ines",
    "Jade",
    "Lina",
    "Louis",
    "Lucas",
    "Luna",
    "Malik",
    "Manon",
    "Maya",
    "Mehdi",
    "Nina",
    "Noah",
    "Nora",
    "Rayan",
    "Sarah",
    "Sofia",
    "Yanis",
    "Yasmine",
    "Zoe"
  ]

  def get_or_create_from_claims(%{uid: uid, email: email}) do
    case Repo.get_by(User, firebase_uid: uid) do
      nil ->
        %User{}
        |> User.auth_changeset(%{firebase_uid: uid, email: email})
        |> Repo.insert()

      %User{} = user ->
        update_email_if_changed(user, email)
    end
  end

  def update_name(%User{} = user, attrs) do
    user
    |> User.name_changeset(attrs)
    |> Repo.update()
  end

  def update_age(%User{} = user, attrs) do
    user
    |> User.age_changeset(attrs)
    |> Repo.update()
  end

  def update_audio_bio(%User{} = user, attrs) do
    user
    |> User.audio_bio_changeset(attrs)
    |> Repo.update()
  end

  def update_profile_picture(%User{} = user, attrs) do
    user
    |> User.profile_picture_changeset(attrs)
    |> Repo.update()
  end

  def onboarding_payload(%User{} = user) do
    %{completed: User.onboarding_completed?(user), missing_fields: missing_fields(user)}
  end

  def update_gender(%User{} = user, attrs) do
    user
    |> User.gender_changeset(attrs)
    |> Repo.update()
  end

  def update_location(%User{} = user, attrs) do
    user
    |> User.location_changeset(attrs)
    |> Repo.update()
  end

  def update_matching_preferences(%User{} = user, attrs) do
    user
    |> User.matching_preferences_changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  def user_response(%User{} = user) do
    %{
      uid: user.firebase_uid,
      email: user.email,
      name: user.name,
      age: user.age,
      gender: user.gender,
      audio_bio: user.audio_bio,
      profile_picture: user.profile_picture,
      latitude: user.latitude,
      longitude: user.longitude
    }
  end

  def preferences_response(%User{} = user) do
    %{
      min_age: user.pref_min_age,
      max_age: user.pref_max_age,
      max_distance_km: user.pref_max_distance_km,
      preferred_gender: user.pref_gender
    }
  end

  def errors_on(changeset) do
    traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  def seed_fake_profiles(count \\ 30) when is_integer(count) and count > 0 do
    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(1..count, fn index ->
        min_age = 18 + rem(index * 3, 23)

        %{
          firebase_uid: "seeded_user_#{index}",
          email: "seeded_user_#{index}@bluette.local",
          name: random_name(),
          age: Enum.random(18..120),
          gender: Enum.at(@seed_genders, rem(index - 1, length(@seed_genders))),
          profile_picture: @profile_picture_url,
          audio_bio: @audio_bio_url,
          latitude: @seed_latitude,
          longitude: @seed_longitude,
          pref_min_age: min_age,
          pref_max_age: min(120, min_age + 5 + rem(index * 5, 20)),
          pref_max_distance_km:
            Enum.at(@seed_max_distance_km, rem(index - 1, length(@seed_max_distance_km))),
          pref_gender:
            Enum.at(@seed_preferred_genders, rem(index - 1, length(@seed_preferred_genders))),
          inserted_at: inserted_at,
          updated_at: inserted_at
        }
      end)

    {count, _rows} =
      Repo.insert_all(User, entries,
        on_conflict:
          {:replace,
           [
             :email,
             :name,
             :age,
             :gender,
             :profile_picture,
             :audio_bio,
             :latitude,
             :longitude,
             :pref_min_age,
             :pref_max_age,
             :pref_max_distance_km,
             :pref_gender,
             :updated_at
           ]},
        conflict_target: [:firebase_uid]
      )

    count
  end

  def clear_user_details(firebase_uid) when is_binary(firebase_uid) do
    case Repo.get_by(User, firebase_uid: firebase_uid) do
      nil ->
        {:error, :user_not_found}

      %User{} = user ->
        user
        |> change(%{name: nil, age: nil, audio_bio: nil, profile_picture: nil})
        |> Repo.update()
    end
  end

  def count_users do
    Repo.aggregate(User, :count)
  end

  def get_user_by_uid(firebase_uid) when is_binary(firebase_uid) do
    Repo.get_by(User, firebase_uid: firebase_uid)
  end

  def list_seeded_users do
    from(user in User, where: like(user.firebase_uid, "seeded_user_%"))
    |> Repo.all()
  end

  defp update_email_if_changed(%User{email: email} = user, email), do: {:ok, user}

  defp update_email_if_changed(%User{} = user, email) do
    user
    |> User.auth_changeset(%{firebase_uid: user.firebase_uid, email: email})
    |> Repo.update()
  end

  defp missing_fields(%User{} = user) do
    []
    |> maybe_add_missing(user.name, "name")
    |> maybe_add_missing(user.age, "age")
    |> maybe_add_missing(user.gender, "gender")
    |> maybe_add_missing(user.audio_bio, "audio_bio")
    |> maybe_add_missing(user.profile_picture, "profile_picture")
    |> maybe_add_missing(user.pref_min_age, "pref_min_age")
    |> maybe_add_missing(user.pref_max_age, "pref_max_age")
    |> maybe_add_missing(user.pref_max_distance_km, "pref_max_distance_km")
    |> maybe_add_missing(user.pref_gender, "pref_gender")
  end

  defp maybe_add_missing(acc, nil, field), do: acc ++ [field]
  defp maybe_add_missing(acc, "", field), do: acc ++ [field]
  defp maybe_add_missing(acc, _value, _field), do: acc

  defp random_name do
    Enum.random(@first_names)
  end
end
