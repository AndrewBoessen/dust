defmodule Dust.Daemon.PeerMonitor do
  @moduledoc """
  Aggregates network metrics (latency, bandwidth) passively based on active 
  file transfers and shard reconstruction traffic.

  Defers simple online/offline tracking to Dust.Mesh.NodeRegistry.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs the latency observed during an active network transmission via dust_bridge.
  """
  def record_latency(node, latency_ms) do
    GenServer.cast(__MODULE__, {:record_latency, node, latency_ms})
  end

  @doc """
  Logs the physical transfer rate of an active network payload via dust_bridge.
  """
  def record_bandwidth(node, bytes, duration_ms) do
    GenServer.cast(__MODULE__, {:record_bandwidth, node, bytes, duration_ms})
  end

  @doc """
  Returns the aggregated metrics table for routing decisions.
  """
  def metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting Peer Monitor metrics aggregator.")
    # State holds a mapping of node -> %{avg_latency: ms, avg_throughput_kbps: ...}
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record_latency, node, latency_ms}, state) do
    # 1. Look up existing metrics for node
    # 2. Apply moving average calculation
    # 3. Store updated stats
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_bandwidth, node, bytes, duration_ms}, state) do
    # 1. Calculate rate
    # 2. Apply moving average calculation
    # 3. Store updated stats
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, state, state}
  end
end
