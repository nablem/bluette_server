defmodule BluetteServer.Accounts do
  import Ecto.Changeset
  import Ecto.Query

  alias BluetteServer.Accounts.Meeting
  alias BluetteServer.Accounts.Swipe
  alias BluetteServer.Accounts.User
  alias BluetteServer.Repo

  @profile_picture_url "https://dessindigo.com/storage/images/posts/bob-eponge/dessin-bob-eponge.webp"
  @audio_bio_url "https://upload.wikimedia.org/wikipedia/commons/1/1f/Fundaci%C3%B3n_Joaqu%C3%ADn_D%C3%ADaz_-_ATO_00446_13_-_Rosario_de_Las_quince_rosas_de_Mar%C3%ADa.ogg"
  @seed_latitude 48.867178137901746
  @seed_longitude 2.2688445113445654
  @seed_genders ["male", "female", "other"]
  @seed_preferred_genders ["male", "female", "everyone"]
  @seed_max_distance_km [5, 10, 25, 50, 100]
  @default_visibility_rank 100
  @meeting_cancellation_penalty 20
  @meeting_placeholder_place "closest_bar_pending_import"
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
        |> User.auth_changeset(%{
          firebase_uid: uid,
          email: email,
          visibility_rank: @default_visibility_rank
        })
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

  def home_payload(%User{} = user) do
    case upcoming_meeting_for(user.id) do
      nil ->
        %{
          mode: "stack",
          can_swipe: true,
          profile: next_profile_for(user) |> maybe_profile_payload()
        }

      meeting ->
        %{
          mode: "meeting",
          can_swipe: false,
          meeting: meeting_payload(meeting, user.id)
        }
    end
  end

  def swipe_profile(%User{} = user, attrs) when is_map(attrs) do
    with :ok <- ensure_user_can_swipe(user.id),
         {:ok, target_uid} <- fetch_string(attrs, "target_uid"),
         {:ok, decision} <- fetch_decision(attrs),
         {:ok, target_user} <- fetch_target_user(user.id, target_uid),
         :ok <- ensure_user_can_be_targeted(target_user.id),
         {:ok, _swipe} <- create_or_update_swipe(user.id, target_user.id, decision) do
      case maybe_create_meeting(user, target_user, decision) do
        {:ok, meeting} -> {:ok, %{match_created: true, meeting: meeting_payload(meeting, user.id)}}
        :no_match -> {:ok, %{match_created: false}}
      end
    end
  end

  def cancel_upcoming_meeting(%User{} = user) do
    case upcoming_meeting_for(user.id) do
      nil ->
        {:error, :no_upcoming_meeting}

      meeting ->
        Repo.transaction(fn ->
          {:ok, cancelled_meeting} =
            meeting
            |> Meeting.cancel_changeset(user.id)
            |> Repo.update()

          _ = lower_visibility_rank(user)

          cancelled_meeting
        end)
    end
    |> unwrap_transaction()
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
          visibility_rank: @default_visibility_rank,
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
             :visibility_rank,
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

  def upcoming_meeting_for_user(firebase_uid) when is_binary(firebase_uid) do
    with %User{} = user <- Repo.get_by(User, firebase_uid: firebase_uid),
         %Meeting{} = meeting <- upcoming_meeting_for(user.id) do
      {:ok, meeting_payload(meeting, user.id)}
    else
      nil -> {:error, :not_found}
    end
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

  defp maybe_profile_payload(nil), do: nil

  defp maybe_profile_payload(%User{} = user) do
    %{
      uid: user.firebase_uid,
      name: user.name,
      age: user.age,
      gender: user.gender,
      audio_bio: user.audio_bio,
      profile_picture: user.profile_picture
    }
  end

  defp fetch_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :validation_failed}
    end
  end

  defp fetch_decision(%{"decision" => decision}) when decision in ["like", "pass"],
    do: {:ok, decision}

  defp fetch_decision(_attrs), do: {:error, :invalid_swipe_decision}

  defp fetch_target_user(current_user_id, target_uid) do
    case Repo.get_by(User, firebase_uid: target_uid) do
      nil ->
        {:error, :target_not_found}

      %User{id: ^current_user_id} ->
        {:error, :cannot_swipe_self}

      %User{} = target_user ->
        {:ok, target_user}
    end
  end

  defp ensure_user_can_swipe(user_id) do
    if upcoming_meeting_for(user_id) do
      {:error, :meeting_in_progress}
    else
      :ok
    end
  end

  defp ensure_user_can_be_targeted(target_user_id) do
    if upcoming_meeting_for(target_user_id) do
      {:error, :target_unavailable}
    else
      :ok
    end
  end

  defp create_or_update_swipe(swiper_user_id, swiped_user_id, decision) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      swiper_user_id: swiper_user_id,
      swiped_user_id: swiped_user_id,
      decision: decision,
      inserted_at: now,
      updated_at: now
    }

    {count, _rows} =
      Repo.insert_all(Swipe, [attrs],
        on_conflict: {:replace, [:decision, :updated_at]},
        conflict_target: [:swiper_user_id, :swiped_user_id]
      )

    if count == 1 do
      {:ok, :recorded}
    else
      {:error, :unable_to_save_swipe}
    end
  end

  defp maybe_create_meeting(_user, _target_user, "pass"), do: :no_match

  defp maybe_create_meeting(%User{} = user, %User{} = target_user, "like") do
    reciprocal_like? =
      from(s in Swipe,
        where:
          s.swiper_user_id == ^target_user.id and s.swiped_user_id == ^user.id and
            s.decision == "like",
        select: count(s.id) > 0
      )
      |> Repo.one()

    if reciprocal_like? do
      if upcoming_meeting_for(user.id) || upcoming_meeting_for(target_user.id) do
        :no_match
      else
        create_meeting(user, target_user)
      end
    else
      :no_match
    end
  end

  defp create_meeting(%User{} = user_a, %User{} = user_b) do
    {place_latitude, place_longitude} = midpoint(user_a, user_b)

    attrs = %{
      user_a_id: user_a.id,
      user_b_id: user_b.id,
      status: "upcoming",
      scheduled_for: next_evening_slot(),
      place_name: @meeting_placeholder_place,
      place_latitude: place_latitude,
      place_longitude: place_longitude
    }

    %Meeting{}
    |> Meeting.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, meeting} -> {:ok, meeting}
      _ -> :no_match
    end
  end

  defp midpoint(%User{} = user_a, %User{} = user_b) do
    if is_number(user_a.latitude) && is_number(user_a.longitude) && is_number(user_b.latitude) &&
         is_number(user_b.longitude) do
      {(user_a.latitude + user_b.latitude) / 2.0, (user_a.longitude + user_b.longitude) / 2.0}
    else
      {nil, nil}
    end
  end

  defp next_evening_slot do
    day_offset = Enum.random(1..3)
    hour = Enum.random(18..21)

    date = Date.utc_today() |> Date.add(day_offset)
    naive = NaiveDateTime.new!(date, Time.new!(hour, 0, 0))

    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp upcoming_meeting_for(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(m in Meeting,
      where:
        m.status == "upcoming" and m.scheduled_for > ^now and
          (m.user_a_id == ^user_id or m.user_b_id == ^user_id),
      order_by: [asc: m.scheduled_for],
      limit: 1
    )
    |> Repo.one()
  end

  defp next_profile_for(%User{} = user) do
    swiped_ids =
      from(s in Swipe,
        where: s.swiper_user_id == ^user.id,
        select: s.swiped_user_id
      )
      |> Repo.all()

    from(candidate in User,
      where: candidate.id != ^user.id,
      where: not is_nil(candidate.name),
      where: not is_nil(candidate.age),
      where: not is_nil(candidate.gender),
      where: not is_nil(candidate.audio_bio),
      where: not is_nil(candidate.profile_picture),
      where: not is_nil(candidate.pref_min_age),
      where: not is_nil(candidate.pref_max_age),
      where: not is_nil(candidate.pref_max_distance_km),
      where: not is_nil(candidate.pref_gender),
      where: candidate.id not in ^swiped_ids,
      order_by: [desc: candidate.visibility_rank, asc: candidate.id]
    )
    |> Repo.all()
    |> Enum.reject(&(upcoming_meeting_for(&1.id) != nil))
    |> Enum.filter(&matches_user_preferences?(user, &1))
    |> Enum.filter(&matches_user_preferences?(&1, user))
    |> Enum.filter(&within_distance?(&1, user))
    |> List.first()
  end

  defp matches_user_preferences?(%User{} = owner, %User{} = candidate) do
    gender_ok?(owner.pref_gender, candidate.gender) and
      age_ok?(owner.pref_min_age, owner.pref_max_age, candidate.age)
  end

  defp gender_ok?("everyone", _candidate_gender), do: true
  defp gender_ok?(pref_gender, candidate_gender), do: pref_gender == candidate_gender

  defp age_ok?(nil, nil, _candidate_age), do: true

  defp age_ok?(min_age, max_age, candidate_age)
       when is_integer(min_age) and is_integer(max_age) and is_integer(candidate_age) do
    candidate_age >= min_age and candidate_age <= max_age
  end

  defp age_ok?(_, _, _), do: true

  defp within_distance?(%User{} = user_a, %User{} = user_b) do
    if is_integer(user_a.pref_max_distance_km) do
      case distance_km(user_a, user_b) do
        nil -> true
        distance -> distance <= user_a.pref_max_distance_km
      end
    else
      true
    end
  end

  defp distance_km(%User{} = user_a, %User{} = user_b) do
    if is_number(user_a.latitude) && is_number(user_a.longitude) && is_number(user_b.latitude) &&
         is_number(user_b.longitude) do
      haversine_km(user_a.latitude, user_a.longitude, user_b.latitude, user_b.longitude)
    else
      nil
    end
  end

  defp haversine_km(lat1, lon1, lat2, lon2) do
    radius = 6_371.0
    d_lat = deg_to_rad(lat2 - lat1)
    d_lon = deg_to_rad(lon2 - lon1)

    a =
      :math.sin(d_lat / 2) * :math.sin(d_lat / 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
          :math.sin(d_lon / 2) * :math.sin(d_lon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    radius * c
  end

  defp deg_to_rad(degrees), do: degrees * :math.pi() / 180.0

  defp meeting_payload(%Meeting{} = meeting, current_user_id) do
    user_a = Repo.get(User, meeting.user_a_id)
    user_b = Repo.get(User, meeting.user_b_id)

    other_user =
      if current_user_id == meeting.user_a_id do
        user_b
      else
        user_a
      end

    %{
      id: meeting.id,
      status: meeting.status,
      scheduled_for: DateTime.to_iso8601(meeting.scheduled_for),
      place: %{
        name: meeting.place_name,
        latitude: meeting.place_latitude,
        longitude: meeting.place_longitude
      },
      with_user: maybe_profile_payload(other_user)
    }
  end

  defp lower_visibility_rank(%User{} = user) do
    next_rank = max((user.visibility_rank || @default_visibility_rank) - @meeting_cancellation_penalty, 0)

    user
    |> change(%{visibility_rank: next_rank})
    |> Repo.update()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp random_name do
    Enum.random(@first_names)
  end
end
