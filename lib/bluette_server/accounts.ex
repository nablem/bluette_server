defmodule BluetteServer.Accounts do
  import Ecto.Changeset
  import Ecto.Query

  alias BluetteServer.Accounts.Bar
  alias BluetteServer.Accounts.Meeting
  alias BluetteServer.Accounts.MeetingSurvey
  alias BluetteServer.Accounts.Swipe
  alias BluetteServer.Accounts.User
  alias BluetteServer.Notifications
  alias BluetteServer.Repo

  @profile_picture_url "https://dessindigo.com/storage/images/posts/bob-eponge/dessin-bob-eponge.webp"
  @audio_bio_url "https://upload.wikimedia.org/wikipedia/commons/1/1f/Fundaci%C3%B3n_Joaqu%C3%ADn_D%C3%ADaz_-_ATO_00446_13_-_Rosario_de_Las_quince_rosas_de_Mar%C3%ADa.ogg"
  @seed_latitude 48.867178137901746
  @seed_longitude 2.2688445113445654
  @seed_genders ["male", "female", "other"]
  @seed_preferred_genders ["female", "male", "everyone", "male", "female"]
  @seed_max_distance_km [5, 10, 25, 50, 100]
  @default_visibility_rank 100
  @meeting_cancellation_penalty 20
  @meeting_survey_rank_delta 5
  @due_meeting_grace_hours 12
  @meeting_placeholder_place "closest_bar_pending_import"
  @paris_timezone "Europe/Paris"
  @weekdays ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
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
    mark_due_meetings_for_user(user.id)
    mark_happening_meetings_for_user(user.id)

    case upcoming_meeting_for(user.id) do
      nil ->
        case pending_due_survey_for(user.id) do
          nil ->
            %{
              mode: "stack",
              can_swipe: true,
              profile: next_profile_for(user) |> maybe_profile_payload()
            }

          meeting ->
            %{
              mode: "survey",
              can_swipe: false,
              survey: %{meeting: meeting_payload(meeting, user.id)}
            }
        end

      meeting ->
        %{
          mode: "meeting",
          can_swipe: false,
          meeting: meeting_payload(meeting, user.id)
        }
    end
  end

  def submit_meeting_survey(%User{} = user, attrs) when is_map(attrs) do
    mark_due_meetings_for_user(user.id)
    mark_happening_meetings_for_user(user.id)

    with {:ok, attended} <- fetch_attended(attrs),
         %Meeting{} = meeting <- pending_due_survey_for(user.id) do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        survey_attrs = %{
          meeting_id: meeting.id,
          user_id: user.id,
          attended: attended,
          answered_at: now
        }

        case %MeetingSurvey{} |> MeetingSurvey.create_changeset(survey_attrs) |> Repo.insert() do
          {:ok, _survey} ->
            refreshed_meeting = Repo.get!(Meeting, meeting.id)
            maybe_apply_survey_outcome(refreshed_meeting, now)

            %{meeting_id: meeting.id, attended: attended}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> unwrap_transaction()
    else
      nil -> {:error, :no_due_meeting_survey}
      error -> error
    end
  end

  def swipe_profile(%User{} = user, attrs) when is_map(attrs) do
    mark_due_meetings_for_user(user.id)
    mark_happening_meetings_for_user(user.id)

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
    mark_due_meetings_for_user(user.id)
    mark_happening_meetings_for_user(user.id)

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
          _ =
            Notifications.notify_meeting_event(
              cancelled_meeting,
              "meeting_cancelled",
              %{cancelled_by_uid: user.firebase_uid}
            )

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
          age: Enum.random(20..38),
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
            Enum.at(@seed_preferred_genders, rem(index, length(@seed_preferred_genders))),
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

  def count_bars do
    Repo.aggregate(Bar, :count)
  end

  def import_bars_from_json(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_list(decoded) do
      import_bars(decoded)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_json}
    end
  end

  def import_bars(rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      rows
      |> Enum.map(&normalize_bar_row(&1, now))
      |> Enum.reject(&is_nil/1)

    case entries do
      [] ->
        {:error, :no_valid_rows}

      _ ->
        {count, _rows} =
          Repo.insert_all(Bar, entries,
            on_conflict:
              {:replace,
               [
                 :name,
                 :address,
                 :locality,
                 :region_code,
                 :latitude,
                 :longitude,
                 :availability,
                 :google_maps_uri,
                 :timezone,
                 :updated_at
               ]},
            conflict_target: [:google_place_id]
          )

        {:ok, count}
    end
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

  defp normalize_bar_row(row, now) when is_map(row) do
    google_place_id = Map.get(row, "google_place_id")
    name = Map.get(row, "name")

    if is_binary(google_place_id) and google_place_id != "" and is_binary(name) and name != "" do
      %{
        google_place_id: google_place_id,
        name: name,
        address: Map.get(row, "address"),
        locality: Map.get(row, "locality"),
        region_code: Map.get(row, "regionCode"),
        latitude: number_or_nil(Map.get(row, "latitude")),
        longitude: number_or_nil(Map.get(row, "longitude")),
        availability: Map.get(row, "availability") || %{},
        google_maps_uri: Map.get(row, "google_maps_uri"),
        timezone: Map.get(row, "timezone") || @paris_timezone,
        inserted_at: now,
        updated_at: now
      }
    else
      nil
    end
  end

  defp normalize_bar_row(_row, _now), do: nil

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

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

  defp fetch_attended(%{"attended" => attended}) when is_boolean(attended), do: {:ok, attended}
  defp fetch_attended(_attrs), do: {:error, :invalid_survey_attended}

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
    cond do
      upcoming_meeting_for(user_id) -> {:error, :meeting_in_progress}
      pending_due_survey_for(user_id) -> {:error, :survey_pending}
      true -> :ok
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
    {mid_latitude, mid_longitude} = midpoint(user_a, user_b)
    {scheduled_for, selected_bar} = schedule_and_select_bar(mid_latitude, mid_longitude)

    place_name =
      if selected_bar do
        selected_bar.name
      else
        @meeting_placeholder_place
      end

    place_latitude = if selected_bar, do: selected_bar.latitude, else: mid_latitude
    place_longitude = if selected_bar, do: selected_bar.longitude, else: mid_longitude

    attrs = %{
      user_a_id: user_a.id,
      user_b_id: user_b.id,
      status: "upcoming",
      scheduled_for: scheduled_for,
      place_name: place_name,
      place_latitude: place_latitude,
      place_longitude: place_longitude
    }

    %Meeting{}
    |> Meeting.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, meeting} ->
        _ = Notifications.notify_meeting_event(meeting, "match_created")
        {:ok, meeting}

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

  defp schedule_and_select_bar(mid_latitude, mid_longitude) do
    bars_count = Repo.aggregate(Bar, :count)

    if bars_count == 0 do
      {next_evening_slot_fallback(), nil}
    else
      slots = candidate_slots()

      Enum.find_value(slots, fn slot ->
        case nearest_open_bar(mid_latitude, mid_longitude, slot) do
          nil -> nil
          bar -> {slot, bar}
        end
      end) || {next_evening_slot_fallback(), nil}
    end
  end

  defp candidate_slots do
    paris_now = DateTime.now!(@paris_timezone)

    for day_offset <- 1..3,
        hour <- 18..21 do
      date = Date.add(DateTime.to_date(paris_now), day_offset)
      naive = NaiveDateTime.new!(date, Time.new!(hour, 0, 0))

      naive
      |> DateTime.from_naive!(@paris_timezone)
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
    end
  end

  defp nearest_open_bar(mid_latitude, mid_longitude, scheduled_for_utc) do
    bars = Repo.all(Bar)

    bars
    |> Enum.filter(&bar_open_at?(&1, scheduled_for_utc))
    |> Enum.sort_by(&distance_to_midpoint(&1, mid_latitude, mid_longitude))
    |> List.first()
  end

  defp distance_to_midpoint(%Bar{} = bar, mid_latitude, mid_longitude) do
    if is_number(mid_latitude) and is_number(mid_longitude) and is_number(bar.latitude) and
         is_number(bar.longitude) do
      haversine_km(mid_latitude, mid_longitude, bar.latitude, bar.longitude)
    else
      0.0
    end
  end

  defp bar_open_at?(%Bar{} = bar, scheduled_for_utc) do
    timezone = bar.timezone || @paris_timezone
    local_dt = DateTime.shift_zone!(scheduled_for_utc, timezone)
    weekday = weekday_name(local_dt)

    case get_in(bar.availability || %{}, [weekday]) do
      %{"start" => start_time, "end" => end_time} ->
        within_opening_hours?(local_dt, start_time, end_time)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp weekday_name(%DateTime{} = dt) do
    Enum.at(@weekdays, Date.day_of_week(DateTime.to_date(dt)) - 1)
  end

  defp within_opening_hours?(local_dt, start_time, end_time)
       when is_binary(start_time) and is_binary(end_time) do
    with {:ok, start_minutes} <- parse_minutes(start_time),
         {:ok, end_minutes} <- parse_minutes(end_time) do
      meeting_minutes = local_dt.hour * 60 + local_dt.minute
      meeting_minutes >= start_minutes and meeting_minutes <= end_minutes
    else
      _ -> false
    end
  end

  defp within_opening_hours?(_local_dt, _start_time, _end_time), do: false

  defp parse_minutes(value) do
    case String.split(value, ":") do
      [h, m] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m),
             true <- hour in 0..23,
             true <- minute in 0..59 do
          {:ok, hour * 60 + minute}
        else
          _ -> {:error, :invalid_time}
        end

      _ ->
        {:error, :invalid_time}
    end
  end

  defp next_evening_slot_fallback do
    paris_now = DateTime.now!(@paris_timezone)
    date = Date.add(DateTime.to_date(paris_now), 1)
    naive = NaiveDateTime.new!(date, ~T[19:00:00])

    naive
    |> DateTime.from_naive!(@paris_timezone)
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp mark_due_meetings_for_user(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    grace_seconds = @due_meeting_grace_hours * 3600
    cutoff = DateTime.add(now, -grace_seconds, :second)

    meetings =
      from(m in Meeting,
        where:
          m.status in ["upcoming", "happening"] and m.scheduled_for <= ^cutoff and
            (m.user_a_id == ^user_id or m.user_b_id == ^user_id)
      )
      |> Repo.all()

    meeting_ids = Enum.map(meetings, & &1.id)

    if meeting_ids != [] do
      from(m in Meeting,
        where: m.id in ^meeting_ids
      )
      |> Repo.update_all(set: [status: "due", updated_at: now])

      Enum.each(meetings, fn meeting ->
        due_meeting = %{meeting | status: "due", updated_at: now}
        _ = Notifications.notify_meeting_event(due_meeting, "meeting_due")
        _ = Notifications.notify_meeting_event(due_meeting, "meeting_survey_required")
      end)
    end
  end

  defp mark_happening_meetings_for_user(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    grace_seconds = @due_meeting_grace_hours * 3600
    cutoff = DateTime.add(now, -grace_seconds, :second)

    meetings =
      from(m in Meeting,
        where:
          m.status == "upcoming" and m.scheduled_for <= ^now and m.scheduled_for > ^cutoff and
            (m.user_a_id == ^user_id or m.user_b_id == ^user_id)
      )
      |> Repo.all()

    meeting_ids = Enum.map(meetings, & &1.id)

    if meeting_ids != [] do
      from(m in Meeting,
        where: m.id in ^meeting_ids
      )
      |> Repo.update_all(set: [status: "happening", updated_at: now])

      Enum.each(meetings, fn meeting ->
        happening_meeting = %{meeting | status: "happening", updated_at: now}
        _ = Notifications.notify_meeting_event(happening_meeting, "meeting_happening")
      end)
    end
  end

  defp upcoming_meeting_for(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    grace_seconds = @due_meeting_grace_hours * 3600
    cutoff = DateTime.add(now, -grace_seconds, :second)

    from(m in Meeting,
      where:
        m.status in ["upcoming", "happening"] and m.scheduled_for > ^cutoff and
          (m.user_a_id == ^user_id or m.user_b_id == ^user_id),
      order_by: [asc: m.scheduled_for],
      limit: 1
    )
    |> Repo.one()
  end

  defp pending_due_survey_for(user_id) do
    from(m in Meeting,
      left_join: survey in MeetingSurvey,
      on: survey.meeting_id == m.id and survey.user_id == ^user_id,
      where:
        m.status == "due" and is_nil(survey.id) and
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

  defp maybe_apply_survey_outcome(%Meeting{} = meeting, now) do
    surveys =
      from(s in MeetingSurvey,
        where: s.meeting_id == ^meeting.id
      )
      |> Repo.all()

    if length(surveys) == 2 do
      attended_values = Enum.map(surveys, & &1.attended)

      {outcome, rank_delta} =
        cond do
          Enum.all?(attended_values) -> {"both_yes", @meeting_survey_rank_delta}
          Enum.all?(attended_values, &(not &1)) -> {"both_no", -@meeting_survey_rank_delta}
          true -> {"mixed", 0}
        end

      {updated_count, _} =
        from(m in Meeting,
          where: m.id == ^meeting.id and is_nil(m.survey_resolved_at)
        )
        |> Repo.update_all(set: [survey_outcome: outcome, survey_resolved_at: now, updated_at: now])

      if updated_count == 1 do
        if rank_delta != 0 do
          _ = adjust_visibility_rank(meeting.user_a_id, rank_delta)
          _ = adjust_visibility_rank(meeting.user_b_id, rank_delta)
        end

        resolved_meeting = %{meeting | survey_outcome: outcome, survey_resolved_at: now, updated_at: now}

        _ =
          Notifications.notify_meeting_event(
            resolved_meeting,
            "meeting_survey_resolved",
            %{survey_outcome: outcome, rank_delta: rank_delta}
          )
      end
    end
  end

  defp lower_visibility_rank(%User{} = user) do
    adjust_visibility_rank(user.id, -@meeting_cancellation_penalty)
  end

  defp adjust_visibility_rank(user_id, delta) when is_integer(user_id) and is_integer(delta) do
    user = Repo.get(User, user_id)
    current = (user && user.visibility_rank) || @default_visibility_rank
    next_rank = max(current + delta, 0)

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
