defmodule Dust.Bridge.Discovery do
  @moduledoc """
  Periodically discovers peer dust nodes and connects them to the Erlang
  cluster.

  Uses `Dust.Bridge.get_peers/0` to query the Go `tsnet_sidecar` for the
  names of peers on the same Tailnet, then calls `Node.connect/1` for any
  peer not already in `Node.list/0`. Each peer is identified by its
  chosen short name; this module builds the node atom as
  `:"dust@<name>"`. The custom EPMD module (`Dust.Bridge.EPMD`) resolves
  the name to a Tailscale IP and proxies the distribution traffic.

  Because routing is name-based, peers running under different node
  names (configured via `dustctl init`) discover each other correctly
  and the Erlang handshake's name comparison succeeds: both sides agree
  on the atom `dust@<name>` without encoding any IP.

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
  defp connect_to_peers(peer_names) do
    self_name = Dust.Utilities.Config.node_name()

    peer_names
    |> Enum.reject(&(&1 == self_name or &1 == ""))
    |> Enum.each(fn name ->
      peer_node = String.to_atom("dust@" <> name)

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
