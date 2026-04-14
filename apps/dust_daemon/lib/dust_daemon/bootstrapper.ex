defmodule Dust.Daemon.Bootstrapper do
  @moduledoc """
  Transient startup task that validates network alignment before the
  operational daemons (`DiskManager`, `GarbageCollector`, `RepairScheduler`)
  are started by the supervisor.

  Because `DustDaemon.Supervisor` uses `:one_for_one` and starts children
  sequentially, `run/1` naturally **blocks** all downstream children until
  it returns — acting as a startup gate.

  ## Phases

    1. **Bridge sidecar health** — retries a probe command until the Go
       `tsnet_sidecar` is responsive.
    2. **Peer discovery** — waits for `Dust.Bridge.Discovery` to form
       initial Erlang cluster connections.
    3. **CRDT convergence** — confirms all DeltaCrdt processes are alive
       and have completed initial disk-load + delta exchange.
    4. **Manifest sync** — forces a neighbour re-announce on every CRDT
       to accelerate delta recovery after a reconnection.
    5. **System ready** — sets the global `Dust.Daemon.Readiness` flag
       and broadcasts `{:system_ready, node()}` via PubSub.

  If any critical phase fails exhaustively, the task crashes, preventing
  downstream children from starting (correct safety behaviour).
  """

  use Task
  require Logger

  alias Dust.Daemon.Readiness

  # ── CRDT process names (mirrored from SharedMap macro) ──────────────

  @crdt_modules [
    Dust.Mesh.FileSystem.DirMap,
    Dust.Mesh.FileSystem.FileMap,
    Dust.Mesh.Manifest.FileIndex,
    Dust.Mesh.Manifest.ChunkIndex,
    Dust.Mesh.Manifest.ShardMap
  ]

  # DeltaCrdt processes are registered as :"Elixir.<Module>.CRDT"
  @crdt_names Enum.map(@crdt_modules, fn mod -> :"#{mod}.CRDT" end)

  # ── Phase tunables ──────────────────────────────────────────────────

  @bridge_max_retries 30
  @bridge_retry_delay_ms 1_000

  @peer_min_wait_ms 5_000
  @peer_max_wait_ms 15_000
  @peer_poll_interval_ms 500

  @crdt_convergence_timeout_ms 15_000
  @crdt_poll_interval_ms 200

  # PubSub topic for system readiness broadcast
  @ready_topic :system_ready

  # ── Public ─────────────────────────────────────────────────────────

  def start_link(arg) do
    Task.start_link(__MODULE__, :run, [arg])
  end

  def run(_arg) do
    Logger.info("Bootstrapper: starting startup validation sequence…")
    t_start = System.monotonic_time(:millisecond)

    # Phase 1
    await_bridge_ready()

    # Phase 2
    await_cluster_peers()

    # Phase 3
    await_crdt_convergence()

    # Phase 4
    trigger_manifest_sync()

    # Phase 5
    mark_system_ready()

    elapsed = System.monotonic_time(:millisecond) - t_start

    Logger.info(
      "Bootstrapper: system successfully bootstrapped in #{elapsed}ms " <>
        "(#{length(Node.list())} peers connected)"
    )
  end

  # ── Phase 1: Bridge Sidecar Health Check ────────────────────────────

  @spec await_bridge_ready() :: :ok
  defp await_bridge_ready do
    if bridge_disabled?() do
      Logger.info("Bootstrapper [1/5]: bridge sidecar disabled — skipping health check")
      :ok
    else
      Logger.info("Bootstrapper [1/5]: checking bridge sidecar health…")
      do_await_bridge(1)
    end
  end

  @spec do_await_bridge(pos_integer()) :: :ok
  defp do_await_bridge(attempt) when attempt > @bridge_max_retries do
    Logger.error(
      "Bootstrapper [1/5]: bridge sidecar did not become ready after " <>
        "#{@bridge_max_retries} attempts — crashing to prevent unsafe startup"
    )

    raise "Bridge sidecar health check failed after #{@bridge_max_retries} retries"
  end

  defp do_await_bridge(attempt) do
    case safe_bridge_probe() do
      :ok ->
        Logger.info("Bootstrapper [1/5]: bridge sidecar healthy (attempt #{attempt})")
        :ok

      {:error, reason} ->
        Logger.debug(
          "Bootstrapper [1/5]: bridge probe attempt #{attempt} failed: #{inspect(reason)}"
        )

        Process.sleep(@bridge_retry_delay_ms)
        do_await_bridge(attempt + 1)
    end
  end

  # Probe the sidecar with a harmless command. Catches all failure modes
  # (port not open, sidecar initializing, GenServer not started, etc.).
  @spec safe_bridge_probe() :: :ok | {:error, term()}
  defp safe_bridge_probe do
    Dust.Bridge.get_peers()
    |> case do
      {:ok, _peers} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec bridge_disabled?() :: boolean()
  defp bridge_disabled? do
    Application.get_env(:dust_bridge, :start_sidecar, true) == false
  end

  # ── Phase 2: Peer Discovery Wait ────────────────────────────────────

  @spec await_cluster_peers() :: :ok
  defp await_cluster_peers do
    Logger.info("Bootstrapper [2/5]: waiting for peer discovery…")

    deadline = System.monotonic_time(:millisecond) + @peer_max_wait_ms
    min_deadline = System.monotonic_time(:millisecond) + @peer_min_wait_ms

    do_await_peers(min_deadline, deadline)
  end

  @spec do_await_peers(integer(), integer()) :: :ok
  defp do_await_peers(min_deadline, max_deadline) do
    now = System.monotonic_time(:millisecond)
    peers = Node.list()

    cond do
      # Minimum wait not elapsed — keep polling regardless
      now < min_deadline ->
        Process.sleep(@peer_poll_interval_ms)
        do_await_peers(min_deadline, max_deadline)

      # Peers found after minimum wait — good to go
      peers != [] ->
        Logger.info("Bootstrapper [2/5]: #{length(peers)} peer(s) discovered")
        :ok

      # Maximum wait exceeded with no peers — genesis/solo node, proceed
      now >= max_deadline ->
        Logger.info("Bootstrapper [2/5]: no peers discovered (genesis/solo node) — proceeding")
        :ok

      # Between min and max wait, no peers yet — keep polling
      true ->
        Process.sleep(@peer_poll_interval_ms)
        do_await_peers(min_deadline, max_deadline)
    end
  end

  # ── Phase 3: CRDT Convergence Gate ──────────────────────────────────

  @spec await_crdt_convergence() :: :ok
  defp await_crdt_convergence do
    Logger.info("Bootstrapper [3/5]: validating CRDT convergence…")

    deadline = System.monotonic_time(:millisecond) + @crdt_convergence_timeout_ms
    do_await_crdts(deadline)

    # If peers are connected, wait a few sync intervals for delta exchange
    if Node.list() != [] do
      Logger.debug("Bootstrapper [3/5]: peers present — waiting for delta exchange…")
      # DeltaCrdt sync_interval is 200ms; wait 3× for comfortable margin
      Process.sleep(600)
    end

    entry_counts = crdt_entry_counts()

    Logger.info(
      "Bootstrapper [3/5]: all #{length(@crdt_names)} CRDTs healthy — " <>
        "entry counts: #{inspect(entry_counts)}"
    )

    :ok
  end

  @spec do_await_crdts(integer()) :: :ok
  defp do_await_crdts(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      # Check one last time — if any CRDT is still down, crash
      unresponsive = Enum.filter(@crdt_names, &(!crdt_alive?(&1)))

      if unresponsive != [] do
        raise "Bootstrapper: CRDT processes not ready after timeout: #{inspect(unresponsive)}"
      end

      :ok
    else
      all_alive = Enum.all?(@crdt_names, &crdt_alive?/1)

      if all_alive do
        :ok
      else
        Process.sleep(@crdt_poll_interval_ms)
        do_await_crdts(deadline)
      end
    end
  end

  @spec crdt_alive?(atom()) :: boolean()
  defp crdt_alive?(crdt_name) do
    case Process.whereis(crdt_name) do
      nil ->
        false

      pid ->
        Process.alive?(pid) and crdt_responsive?(crdt_name)
    end
  end

  @spec crdt_responsive?(atom()) :: boolean()
  defp crdt_responsive?(crdt_name) do
    DeltaCrdt.to_map(crdt_name)
    true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @spec crdt_entry_counts() :: keyword(non_neg_integer())
  defp crdt_entry_counts do
    Enum.map(@crdt_modules, fn mod ->
      crdt_name = :"#{mod}.CRDT"

      count =
        try do
          crdt_name |> DeltaCrdt.to_map() |> map_size()
        rescue
          _ -> 0
        catch
          :exit, _ -> 0
        end

      {mod |> Module.split() |> List.last() |> String.to_atom(), count}
    end)
  end

  # ── Phase 4: Manifest Delta Synchronization ─────────────────────────

  @spec trigger_manifest_sync() :: :ok
  defp trigger_manifest_sync do
    online_nodes = Node.list()

    if online_nodes == [] do
      Logger.info("Bootstrapper [4/5]: no peers — skipping manifest sync")
      :ok
    else
      Logger.info(
        "Bootstrapper [4/5]: triggering manifest sync with #{length(online_nodes)} peer(s)…"
      )

      Enum.each(@crdt_names, fn crdt_name ->
        neighbours = Enum.map(online_nodes, fn node -> {crdt_name, node} end)

        try do
          DeltaCrdt.set_neighbours(crdt_name, neighbours)
        rescue
          e ->
            Logger.warning(
              "Bootstrapper [4/5]: failed to set neighbours for #{crdt_name}: #{Exception.message(e)}"
            )
        catch
          :exit, reason ->
            Logger.warning(
              "Bootstrapper [4/5]: failed to set neighbours for #{crdt_name}: #{inspect(reason)}"
            )
        end
      end)

      # Give one more sync interval for the forced neighbour update to propagate
      Process.sleep(300)

      Logger.info("Bootstrapper [4/5]: manifest sync complete")
      :ok
    end
  end

  # ── Phase 5: System Ready ───────────────────────────────────────────

  @spec mark_system_ready() :: :ok
  defp mark_system_ready do
    Readiness.set_ready()

    # Broadcast to any subscribers listening on the daemon registry
    Registry.dispatch(Dust.Daemon.Registry, @ready_topic, fn subscribers ->
      Enum.each(subscribers, fn {pid, _} ->
        send(pid, {:system_ready, node()})
      end)
    end)

    Logger.info("Bootstrapper [5/5]: system ready flag set ✓")
    :ok
  end
end
