defmodule Dust.Daemon.DiskManager do
  @moduledoc """
  Background daemon that monitors local storage capacities and actively evicts
  highly redundant shards to other nodes when hitting configured disk limits.
  """
  use GenServer
  require Logger

  # 15 minutes
  @audit_interval_ms 60_000 * 15

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting Disk Quota Manager daemon.")
    schedule_audit()
    # Configurable limit
    {:ok, %{quota_bytes: 50_000_000_000}}
  end

  @impl true
  def handle_info(:audit, state) do
    # 1. Check local dust_storage RocksDB directory size
    # 2. If size > quota_bytes, identify least valuable chunks locally
    # 3. Transmit to peer node with available space via dust_bridge
    # 4. Safely evict local ShardMap metadata and drop blocks natively
    schedule_audit()
    {:noreply, state}
  end

  defp schedule_audit do
    Process.send_after(self(), :audit, @audit_interval_ms)
  end
end
