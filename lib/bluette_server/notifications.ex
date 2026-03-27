defmodule BluetteServer.Notifications do
  import Ecto.Query

  alias BluetteServer.Accounts.Meeting
  alias BluetteServer.Accounts.User
  alias BluetteServer.Notifications.Notification
  alias BluetteServer.Repo

  @registry BluetteServer.Notifications.Registry
  @default_limit 50
  @max_limit 200

  def subscribe(user_id) when is_integer(user_id) do
    case Registry.register(@registry, user_id, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  def notify_meeting_event(%Meeting{} = meeting, event_type, extra_payload \\ %{})
      when is_binary(event_type) and is_map(extra_payload) do
    uid_by_id = user_uids_by_ids([meeting.user_a_id, meeting.user_b_id])

    base_payload =
      %{
        meeting_id: meeting.id,
        meeting_status: meeting.status,
        scheduled_for: meeting.scheduled_for,
        place: %{
          name: meeting.place_name,
          latitude: meeting.place_latitude,
          longitude: meeting.place_longitude
        }
      }
      |> Map.merge(extra_payload)

    notify_user(meeting.user_a_id, event_type, Map.put(base_payload, :counterparty_uid, uid_by_id[meeting.user_b_id]))
    notify_user(meeting.user_b_id, event_type, Map.put(base_payload, :counterparty_uid, uid_by_id[meeting.user_a_id]))

    :ok
  end

  def list_user_notifications(user_id, opts \\ []) when is_integer(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
    after_id = Keyword.get(opts, :after_id)

    query =
      from(n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.inserted_at],
        limit: ^limit
      )

    query =
      if is_integer(after_id) do
        from(n in query, where: n.id > ^after_id)
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.map(&serialize/1)
  end

  def unread_count(user_id) when is_integer(user_id) do
    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.read_at),
      select: count(n.id)
    )
    |> Repo.one()
  end

  def mark_as_read(user_id, nil), do: mark_as_read(user_id, :all)

  def mark_as_read(user_id, :all) when is_integer(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.read_at)
    )
    |> Repo.update_all(set: [read_at: now, updated_at: now])
    |> elem(0)
  end

  def mark_as_read(user_id, ids) when is_integer(user_id) and is_list(ids) do
    safe_ids = ids |> Enum.filter(&is_integer/1) |> Enum.uniq()

    if safe_ids == [] do
      0
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(n in Notification,
        where: n.user_id == ^user_id and n.id in ^safe_ids and is_nil(n.read_at)
      )
      |> Repo.update_all(set: [read_at: now, updated_at: now])
      |> elem(0)
    end
  end

  defp notify_user(user_id, event_type, payload)
       when is_integer(user_id) and is_binary(event_type) and is_map(payload) do
    attrs = %{user_id: user_id, event_type: event_type, payload: payload}

    case %Notification{} |> Notification.create_changeset(attrs) |> Repo.insert() do
      {:ok, notification} ->
        payload = serialize(notification)
        broadcast(user_id, payload)
        {:ok, payload}

      {:error, _changeset} = error ->
        error
    end
  end

  defp broadcast(user_id, payload) do
    Registry.dispatch(@registry, user_id, fn entries ->
      Enum.each(entries, fn {pid, _} ->
        send(pid, {:notification, payload})
      end)
    end)
  end

  defp user_uids_by_ids(ids) do
    from(u in User,
      where: u.id in ^ids,
      select: {u.id, u.firebase_uid}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp normalize_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_limit)
  defp normalize_limit(_), do: @default_limit

  defp serialize(%Notification{} = n) do
    %{
      id: n.id,
      event_type: n.event_type,
      payload: n.payload,
      read_at: n.read_at,
      inserted_at: n.inserted_at
    }
  end
end
