defmodule Dust.Bridge.Discovery do
  @moduledoc """
  Periodically discovers peer dust nodes and connects them to the Erlang
  cluster.

  Uses `Dust.Bridge.get_peers/0` to query the Go `tsnet_sidecar` for the
  list of peers on the same Tailnet. Each entry is a `"name@ip"` string
  identifying a peer; this module calls `Node.connect/1` for any peer not
  already in `Node.list/0`. Connection triggers the custom EPMD module
  (`Dust.Bridge.EPMD`) which proxies Erlang distribution traffic through
  the Tailscale tunnel.

  Because each peer's node-name prefix is recovered from its Tailscale
  hostname, peers can run under different node names (configured via
  `dustctl init`) and still discover each other.

  The default poll interval is 15 seconds.
  """
  use GenServer
  require Logger

  @poll_interval 15_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll_peers, state) do
    case Dust.Bridge.get_peers() do
      {:ok, peers} ->
        connect_to_peers(peers)

      {:error, reason} ->
        Logger.warning("Discovery: Failed to get peers from sidecar: #{inspect(reason)}")
    end

    schedule_poll()
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec connect_to_peers([String.t()]) :: :ok
  defp connect_to_peers(peers) do
    self_node = to_string(Node.self())

    peers
    |> Enum.reject(&(&1 == self_node))
    |> Enum.each(fn entry ->
      peer_node = String.to_atom(entry)

      if peer_node not in Node.list() do
        Logger.debug("Discovery: Attempting to connect to #{peer_node}")
        Node.connect(peer_node)
      end
    end)
  end

  @spec schedule_poll() :: reference()
  defp schedule_poll do
    Process.send_after(self(), :poll_peers, @poll_interval)
  end
end
