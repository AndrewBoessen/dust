defmodule Dust.Daemon.BandwidthThrottler do
  @moduledoc """
  System-wide governor token bucket that caps background synchronization and
  repair bandwidth to ensure robust frontend/UI performance.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting Bandwidth Throttler governor.")
    # Initialize connection quotas/token buckets here
    {:ok, %{bg_allowance_kbps: 5000}}
  end

  # External API for daemons to request network budget
  def request_bandwidth(bytes_needed) do
    GenServer.call(__MODULE__, {:request_bandwidth, bytes_needed})
  end

  @impl true
  def handle_call({:request_bandwidth, _bytes}, _from, state) do
    # 1. Calculate running rate limits
    # 2. Block/halt or return :ok based on availability
    {:reply, :ok, state}
  end
end
