defmodule Dust.Api.Handlers.GcHandler do
  @moduledoc """
  Handles garbage collection operations:

    - `GET  /api/v1/gc/stats` — returns GC statistics from the last sweep
    - `POST /api/v1/gc/sweep` — triggers an immediate GC sweep
  """

  import Plug.Conn

  @doc "Returns GC stats from the last completed sweep."
  @spec stats(Plug.Conn.t()) :: Plug.Conn.t()
  def stats(conn) do
    gc_stats = Dust.Daemon.GarbageCollector.stats()

    response = %{
      last_sweep_at: format_datetime(gc_stats.last_sweep_at),
      orphans_removed: gc_stats.last_orphans_removed,
      replicas_removed: gc_stats.last_replicas_removed
    }

    json_response(conn, 200, response)
  end

  @doc "Triggers an immediate GC sweep."
  @spec sweep(Plug.Conn.t()) :: Plug.Conn.t()
  def sweep(conn) do
    :ok = Dust.Daemon.GarbageCollector.sweep_now()
    json_response(conn, 202, %{status: "sweep_triggered"})
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: inspect(other)

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
