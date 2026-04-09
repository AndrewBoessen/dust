defmodule Dust.Daemon.GarbageCollector do
  @moduledoc """
  Background daemon that reclaims local disk space by removing shards that
  are either **orphaned** (no file references them) or **over-replicated**
  (enough other online nodes already hold a copy).

  ## Sweep Phases

  Each sweep executes two sequential phases:

    1. **Orphan sweep** — deletes locally-stored shards whose `chunk_hash`
       is no longer referenced by any file in the distributed `FileIndex`.
       Also removes this node from the `ShardMap` for those shards.

    2. **Replication sweep** — for each remaining local shard, checks how
       many *other online* nodes also hold it. If that count meets or
       exceeds the configured `:replication_factor`, the local copy is
       deleted and the `ShardMap` is updated.

  ## Configuration

      config :dust_daemon,
        replication_factor: 2   # min other-node copies before local eviction

  ## Observability

  Sweep results are logged at `:info` level and available via `stats/0`.
  """

  use GenServer
  require Logger

  alias Dust.Mesh.Manifest.{FileIndex, ShardMap}
  alias Dust.Mesh.NodeRegistry
  alias Dust.Storage
  alias Dust.Utilities.Config

  # Run every hour by default
  @sweep_interval_ms 60_000 * 60

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns statistics from the last completed sweep."
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Triggers an immediate sweep (useful for testing and manual intervention)."
  @spec sweep_now() :: :ok
  def sweep_now, do: GenServer.cast(__MODULE__, :sweep_now)

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("Starting Garbage Collector daemon.")
    schedule_sweep()

    {:ok,
     %{
       last_sweep_at: nil,
       last_orphans_removed: 0,
       last_replicas_removed: 0
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:sweep_now, state) do
    {:noreply, do_sweep(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    new_state = do_sweep(state)
    schedule_sweep()
    {:noreply, new_state}
  end

  # ── Core Sweep Logic ────────────────────────────────────────────────────

  defp do_sweep(state) do
    Logger.debug("GarbageCollector: starting sweep.")

    local_keys = Storage.list_local_shard_keys()

    {remaining_keys, orphans_removed} = sweep_orphans(local_keys)
    replicas_removed = sweep_replicas(remaining_keys)

    Logger.info(
      "GarbageCollector: sweep complete — " <>
        "#{orphans_removed} orphans removed, " <>
        "#{replicas_removed} over-replicated shards removed."
    )

    %{
      state
      | last_sweep_at: DateTime.utc_now(),
        last_orphans_removed: orphans_removed,
        last_replicas_removed: replicas_removed
    }
  end

  # ── Phase 1: Orphan Sweep ───────────────────────────────────────────────

  # Deletes shards whose chunk_hash is not referenced by any file in FileIndex.
  @spec sweep_orphans([{String.t(), non_neg_integer()}]) ::
          {[{String.t(), non_neg_integer()}], non_neg_integer()}
  defp sweep_orphans(local_keys) do
    referenced_chunks = build_referenced_chunks()

    {remaining, removed} =
      Enum.reduce(local_keys, {[], 0}, fn {chunk_hash, shard_index} = key, {kept, count} ->
        if MapSet.member?(referenced_chunks, chunk_hash) do
          {[key | kept], count}
        else
          delete_local_shard(chunk_hash, shard_index, :orphan)
          {kept, count + 1}
        end
      end)

    {remaining, removed}
  end

  # Builds a MapSet of all chunk_hashes currently referenced by at least one file.
  @spec build_referenced_chunks() :: MapSet.t(String.t())
  defp build_referenced_chunks do
    FileIndex.all()
    |> Enum.flat_map(fn {_file_uuid, %{chunks: chunks}} -> chunks end)
    |> MapSet.new()
  end

  # ── Phase 2: Replication Sweep ──────────────────────────────────────────

  # Removes local copies of shards that are sufficiently replicated on other
  # online nodes.
  @spec sweep_replicas([{String.t(), non_neg_integer()}]) :: non_neg_integer()
  defp sweep_replicas(local_keys) do
    replication_factor = Config.replication_factor()
    online_nodes = MapSet.new(NodeRegistry.online_nodes())
    me = node()

    Enum.reduce(local_keys, 0, fn {chunk_hash, shard_index}, count ->
      shard_map = ShardMap.get_shards(chunk_hash)

      case Map.get(shard_map, shard_index) do
        nil ->
          # Shard not tracked in manifest — skip (will be caught as orphan
          # on the next sweep if the chunk is also unreferenced).
          count

        %{nodes: holders} ->
          other_online_holders =
            holders
            |> MapSet.delete(me)
            |> MapSet.intersection(online_nodes)
            |> MapSet.size()

          if other_online_holders >= replication_factor do
            delete_local_shard(chunk_hash, shard_index, :over_replicated)
            count + 1
          else
            count
          end
      end
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp delete_local_shard(chunk_hash, shard_index, reason) do
    Storage.delete_shard(chunk_hash, shard_index)
    ShardMap.remove_node(chunk_hash, shard_index, node())

    Logger.info("GarbageCollector: removed shard #{chunk_hash}:#{shard_index} (#{reason})")
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
