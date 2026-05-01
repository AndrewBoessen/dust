defmodule Dust.Api.Handlers.StatusHandler do
  @moduledoc """
  Handles `GET /api/v1/status` — returns node health, readiness,
  peer count, disk usage, and key store status.
  """

  import Plug.Conn

  @doc "Returns aggregated node status as JSON."
  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    network = network_status()

    status = %{
      node: node() |> to_string(),
      ready: Dust.Daemon.Readiness.ready?(),
      peers: length(Node.list()),
      peer_names: Node.list() |> Enum.map(&to_string/1),
      key_store: key_store_status(),
      disk: disk_status(),
      network: network,
      persist_dir: Dust.Utilities.Config.persist_dir(),
      uptime_ms: :erlang.statistics(:wall_clock) |> elem(0),
      version: "0.1.2"
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

  defp network_status do
    bridge = Application.get_env(:dust_bridge, :bridge_module, Dust.Bridge)

    try do
      auth = try_auth_status(bridge)
      peers = try_peer_count(bridge)

      connected = auth.state == "authenticated"

      %{
        connected: connected,
        state: auth.state,
        self_ip: non_empty(auth.self_ip),
        auth_url: non_empty(auth.auth_url),
        tailscale_peers: peers
      }
    rescue
      _ -> %{connected: false, state: "unknown", self_ip: nil, auth_url: nil, tailscale_peers: 0}
    end
  end

  defp try_auth_status(bridge) do
    case bridge.auth_status() do
      {:ok, status} -> status
      _ -> %{state: "unknown", self_ip: "", auth_url: ""}
    end
  rescue
    _ -> %{state: "unknown", self_ip: "", auth_url: ""}
  end

  defp try_peer_count(bridge) do
    case bridge.get_peers() do
      {:ok, peers} -> length(peers)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp non_empty(""), do: nil
  defp non_empty(val), do: val

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
