defmodule BluetteServer.Accounts do
  import Ecto.Changeset
  import Ecto.Query

  alias BluetteServer.Accounts.User
  alias BluetteServer.Repo

  @profile_picture_url "https://dessindigo.com/storage/images/posts/bob-eponge/dessin-bob-eponge.webp"
  @audio_bio_url "https://upload.wikimedia.org/wikipedia/commons/1/1f/Fundaci%C3%B3n_Joaqu%C3%ADn_D%C3%ADaz_-_ATO_00446_13_-_Rosario_de_Las_quince_rosas_de_Mar%C3%ADa.ogg"
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

  def update_step1(%User{} = user, attrs) do
    user
    |> User.step1_changeset(attrs)
    |> Repo.update()
  end

  def update_step2(%User{} = user, attrs) do
    user
    |> User.step2_changeset(attrs)
    |> Repo.update()
  end

  def update_step3(%User{} = user, attrs) do
    user
    |> User.step3_changeset(attrs)
    |> Repo.update()
  end

  def onboarding_payload(%User{} = user) do
    %{completed: User.onboarding_completed?(user), missing_fields: missing_fields(user)}
  end

  def user_response(%User{} = user) do
    %{
      uid: user.firebase_uid,
      email: user.email,
      name: user.name,
      age: user.age,
      audio_bio: user.audio_bio,
      profile_picture: user.profile_picture
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
        %{
          firebase_uid: "seeded_user_#{index}",
          email: "seeded_user_#{index}@bluette.local",
          name: random_name(),
          age: Enum.random(18..120),
          profile_picture: @profile_picture_url,
          audio_bio: @audio_bio_url,
          inserted_at: inserted_at,
          updated_at: inserted_at
        }
      end)

    {count, _rows} =
      Repo.insert_all(User, entries,
        on_conflict: {:replace, [:email, :name, :age, :profile_picture, :audio_bio, :updated_at]},
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
    |> maybe_add_missing(user.audio_bio, "audio_bio")
    |> maybe_add_missing(user.profile_picture, "profile_picture")
  end

  defp maybe_add_missing(acc, nil, field), do: acc ++ [field]
  defp maybe_add_missing(acc, "", field), do: acc ++ [field]
  defp maybe_add_missing(acc, _value, _field), do: acc

  defp random_name do
    Enum.random(@first_names)
  end
end
