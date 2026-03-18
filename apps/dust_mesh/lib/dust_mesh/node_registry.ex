defmodule Dust.Mesh.NodeRegistry do
  @moduledoc """
  Tracks the status of all nodes in the distributed Erlang cluster.

  Each node runs its own registry. When a node connects, it announces
  its presence to all peers and requests their current state. When a
  node disconnects, :net_kernel delivers a :nodedown event immediately.

  ## State model

  Each peer is tracked with a status and a timestamp:

      %{
        :"dust@100.64.0.2" => %{status: :online,  seen_at: ~U[...]},
        :"dust@100.64.0.3" => %{status: :offline, seen_at: ~U[...]}
      }

  Offline nodes are retained rather than removed so callers can
  distinguish "never seen" from "was online and went away".
  """

  use GenServer

  require Logger

  @type node_status :: :online | :offline
  @type node_entry :: %{status: node_status(), seen_at: DateTime.t()}
  @type registry :: %{node() => node_entry()}

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the full registry map of all known nodes and their status."
  @spec list() :: registry()
  def list() do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Returns only the currently online nodes."
  @spec online_nodes() :: [node()]
  def online_nodes() do
    GenServer.call(__MODULE__, :online_nodes)
  end

  @doc "Returns the status of a specific node."
  @spec status(node()) :: node_status() | :unknown
  def status(node) do
    GenServer.call(__MODULE__, {:status, node})
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # Seed registry from currently connected nodes — these are definitively online
    initial_registry =
      Node.list()
      |> Map.new(fn node -> {node, %{status: :online, seen_at: DateTime.utc_now()}} end)

    # Request full registries from all peers so we learn about
    # nodes that are currently offline but were seen before
    request_sync_from_peers()

    # Tell peers we are online
    announce_presence()

    Logger.info("NodeRegistry: started, #{length(Node.list())} peers connected")
    {:ok, %{registry: initial_registry}}
  end

  # ── Net kernel events ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("NodeRegistry: #{node} connected")

    new_registry = put_entry(state.registry, node, :online)
    request_sync(node)

    {:noreply, %{state | registry: new_registry}}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.info("NodeRegistry: #{node} disconnected")

    new_registry = put_entry(state.registry, node, :offline)

    {:noreply, %{state | registry: new_registry}}
  end

  # ── Peer messages ──────────────────────────────────────────────────────────

  def handle_info({:presence, node}, state) do
    new_registry = put_entry(state.registry, node, :online)
    {:noreply, %{state | registry: new_registry}}
  end

  def handle_info({:sync_request, from_node}, state) do
    send({__MODULE__, from_node}, {:sync_response, Node.self(), state.registry})
    {:noreply, state}
  end

  def handle_info({:sync_response, _from_node, their_registry}, state) do
    new_registry = merge_registries(state.registry, their_registry)
    {:noreply, %{state | registry: new_registry}}
  end

  # ── Calls ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.registry, state}
  end

  def handle_call(:online_nodes, _from, state) do
    online =
      state.registry
      |> Enum.filter(fn {_, entry} -> entry.status == :online end)
      |> Enum.map(fn {node, _} -> node end)

    {:reply, online, state}
  end

  def handle_call({:status, node}, _from, state) do
    status =
      case Map.get(state.registry, node) do
        nil -> :unknown
        entry -> entry.status
      end

    {:reply, status, state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp put_entry(registry, node, status) do
    Map.put(registry, node, %{status: status, seen_at: DateTime.utc_now()})
  end

  defp announce_presence() do
    Enum.each(Node.list(), fn node ->
      send({__MODULE__, node}, {:presence, Node.self()})
    end)
  end

  defp request_sync_from_peers() do
    Enum.each(Node.list(), &request_sync/1)
  end

  defp request_sync(node) do
    send({__MODULE__, node}, {:sync_request, Node.self()})
  end

  defp merge_registries(ours, theirs) do
    Map.merge(ours, theirs, fn _node, our_entry, their_entry ->
      case {our_entry.status, their_entry.status} do
        # We know this node is online via :net_kernel — always trust ourselves
        {:online, _} ->
          our_entry

        # They have positive information we lack
        {:offline, :online} ->
          their_entry

        # Both offline — keep the more recent observation
        {:offline, :offline} ->
          if DateTime.compare(their_entry.seen_at, our_entry.seen_at) == :gt do
            their_entry
          else
            our_entry
          end
      end
    end)
  end
end
