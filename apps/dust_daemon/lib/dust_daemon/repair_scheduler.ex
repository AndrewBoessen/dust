defmodule Dust.Daemon.RepairScheduler do
  @moduledoc """
  Background daemon responsible for monitoring cluster decay and orchestrating shard repair.
  """
  use GenServer
  require Logger

  # Run every 30 minutes by default
  @sweep_interval_ms 60_000 * 30

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting Repair Scheduler daemon.")
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Logger.debug("RepairScheduler: executing sweep.")
    # 1. Audit Dust.Mesh.Manifest.ShardMap for node departures
    # 2. Identify chunks whose mapped replica count falls beneath redundancy threshold
    # 3. Trigger dust_bridge fetches for surviving shards to reach (K)
    # 4. Route to dust_core to reconstitute erasure-coding shards
    # 5. Distribute via dust_bridge to newly available peers
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
