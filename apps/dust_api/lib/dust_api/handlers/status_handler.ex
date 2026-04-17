defmodule Dust.Api.Handlers.StatusHandler do
  @moduledoc """
  Handles `GET /api/v1/status` — returns node health, readiness,
  peer count, disk usage, and key store status.
  """

  import Plug.Conn

  @doc "Returns aggregated node status as JSON."
  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    status = %{
      node: node() |> to_string(),
      ready: Dust.Daemon.Readiness.ready?(),
      peers: length(Node.list()),
      peer_names: Node.list() |> Enum.map(&to_string/1),
      key_store: key_store_status(),
      disk: disk_status(),
      uptime_ms: :erlang.statistics(:wall_clock) |> elem(0),
      version: "0.1.0"
    }

    json_response(conn, 200, status)
  end

  defp key_store_status do
    if Dust.Core.KeyStore.has_key?() do
      "unlocked"
    else
      "locked"
    end
  rescue
    _ -> "unavailable"
  end

  defp disk_status do
    try do
      quota = Dust.Daemon.DiskManager.get_quota()
      persist_dir = Dust.Utilities.Config.persist_dir()
      stats = DiskSpace.stat!(persist_dir)

      %{
        quota_bytes: quota,
        available_bytes: stats.available,
        total_bytes: stats.total
      }
    rescue
      _ -> %{quota_bytes: 0, available_bytes: 0, total_bytes: 0}
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
