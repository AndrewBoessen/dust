defmodule Dust.Daemon.GarbageCollector do
  @moduledoc """
  Background daemon responsible for sweeping unreferenced chunks from local storage.
  """
  use GenServer
  require Logger

  # Run every hour by default
  @sweep_interval_ms 60_000 * 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting Garbage Collector daemon.")
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Logger.debug("GarbageCollector: executing sweep.")
    # 1. Read local hashes parked in dust_storage
    # 2. Check them against cluster presence in dust_mesh.ChunkIndex
    # 3. Purge any raw binary data lacking network citations
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
