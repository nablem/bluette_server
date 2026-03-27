defmodule BluetteServer.Notifications.Stream do
  @moduledoc false

  import Plug.Conn

  alias BluetteServer.Notifications

  @heartbeat_ms 15_000

  def stream(conn, user_id) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")

    conn = send_chunked(conn, 200)
    :ok = Notifications.subscribe(user_id)

    conn
    |> send_event("connected", %{user_id: user_id, unread_count: Notifications.unread_count(user_id)})
    |> stream_loop()
  end

  defp stream_loop(conn) do
    receive do
      {:notification, payload} ->
        conn
        |> send_event("notification", payload)
        |> maybe_continue()
    after
      @heartbeat_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _reason} -> conn
        end
    end
  end

  defp maybe_continue({:halt, conn}), do: conn
  defp maybe_continue(conn), do: stream_loop(conn)

  defp send_event(conn, event_name, payload) do
    data = Jason.encode!(payload)

    case chunk(conn, "event: #{event_name}\ndata: #{data}\n\n") do
      {:ok, conn} -> conn
      {:error, _reason} -> {:halt, conn}
    end
  end
end
