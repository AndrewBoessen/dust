defmodule Dust.Daemon.RepairScheduler do
  @moduledoc """
  Background daemon that autonomously heals the Dust network.

  Runs on every node independently. Never commands other nodes to download
  data — instead, each node **pulls** what the cluster needs and stores it
  locally. Combined with the `GarbageCollector` (which evicts excess),
  this creates an emergent, self-balancing storage system.

  ## Sweep Phases

  Each sweep executes five sequential phases:

    1. **Integrity verification** — validates checksums of locally-held
       shards and purges any that are corrupted.

    2. **Under-replication repair** (clone) — pulls copies of shards that
       have fewer online holders than `replication_factor + 1`.

    3. **Missing shard reconstruction** — for chunks where some shard
       indices have *zero* holders, fetches K surviving shards, erasure-
       decodes, re-encodes, and stores the missing indices locally.

    4. **Stale manifest cleanup** — removes ShardMap entries that reference
       nodes which have been offline longer than `stale_node_timeout_ms`.

  ## Configuration

      config :dust_utilities, :config,
        replication_factor: 2,
        stale_node_timeout_ms: 86_400_000,
        max_reconstruct_per_sweep: 5

  ## Observability

  Sweep results are logged at `:info` level and available via `stats/0`.
  """

  use GenServer
  require Logger

  alias Dust.Core.{ErasureCoding, Fitness}
  alias Dust.Core.Fitness.Observation
  alias Dust.Daemon.DiskManager
  alias Dust.Mesh.Manifest.{FileIndex, ShardMap}
  alias Dust.Mesh.NodeRegistry
  alias Dust.Storage
  alias Dust.Utilities.Config

  # Run every 30 minutes by default
  @sweep_interval_ms 60_000 * 30

  # Timeout for a single shard fetch RPC (ms)
  @shard_fetch_timeout 30_000

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
    Logger.info("Starting Repair Scheduler daemon.")
    schedule_sweep()

    {:ok,
     %{
       last_sweep_at: nil,
       integrity_removed: 0,
       shards_cloned: 0,
       shards_reconstructed: 0,
       stale_entries_cleaned: 0
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
    Logger.debug("RepairScheduler: starting sweep.")

    local_keys = Storage.list_local_shard_keys()
    online_nodes = NodeRegistry.online_nodes()
    all_registry = NodeRegistry.list()
    me = node()

    # Phase 1: Integrity
    {valid_keys, integrity_removed} = sweep_integrity(local_keys)

    # Phase 4 runs before 2-3 so stale entries are cleaned first
    stale_entries_cleaned = sweep_stale_manifest(all_registry)

    # Phase 2: Under-replication repair (clone)
    shards_cloned = sweep_under_replication(valid_keys, online_nodes, me)

    # Phase 3: Missing shard reconstruction
    shards_reconstructed = sweep_reconstruction(online_nodes, me)

    Logger.info(
      "RepairScheduler: sweep complete — " <>
        "#{integrity_removed} corrupt removed, " <>
        "#{stale_entries_cleaned} stale entries cleaned, " <>
        "#{shards_cloned} shards cloned, " <>
        "#{shards_reconstructed} shards reconstructed."
    )

    %{
      state
      | last_sweep_at: DateTime.utc_now(),
        integrity_removed: integrity_removed,
        shards_cloned: shards_cloned,
        shards_reconstructed: shards_reconstructed,
        stale_entries_cleaned: stale_entries_cleaned
    }
  end

  # ── Phase 1: Integrity Verification ─────────────────────────────────────

  @spec sweep_integrity([{String.t(), non_neg_integer()}]) ::
          {[{String.t(), non_neg_integer()}], non_neg_integer()}
  defp sweep_integrity(local_keys) do
    Enum.reduce(local_keys, {[], 0}, fn {chunk_hash, shard_index} = key, {valid, removed} ->
      case Storage.verify_shard(chunk_hash, shard_index) do
        :ok ->
          {[key | valid], removed}

        {:error, reason} ->
          Logger.warning(
            "RepairScheduler: corrupted shard #{chunk_hash}:#{shard_index} (#{inspect(reason)}), removing"
          )

          Storage.delete_shard(chunk_hash, shard_index)
          ShardMap.remove_node(chunk_hash, shard_index, node())
          {valid, removed + 1}
      end
    end)
  end

  # ── Phase 2: Under-Replication Repair (Clone) ───────────────────────────

  @spec sweep_under_replication(
          [{String.t(), non_neg_integer()}],
          [node()],
          node()
        ) :: non_neg_integer()
  defp sweep_under_replication(_valid_keys, online_nodes, me) do
    replication_target = Config.replication_factor() + 1
    online_set = MapSet.new([me | online_nodes])
    referenced_chunks = build_referenced_chunks()

    # Build set of local shard keys for fast membership checks
    local_keys_set =
      Storage.list_local_shard_keys()
      |> MapSet.new()

    referenced_chunks
    |> Enum.reduce(0, fn chunk_hash, total_cloned ->
      shard_map = ShardMap.get_shards(chunk_hash)

      shard_map
      |> Enum.reduce(total_cloned, fn {shard_index, %{nodes: holders}}, cloned ->
        online_holders =
          holders
          |> MapSet.intersection(online_set)

        online_count = MapSet.size(online_holders)
        already_local = MapSet.member?(local_keys_set, {chunk_hash, shard_index})

        if online_count < replication_target and not already_local do
          case clone_shard(chunk_hash, shard_index, online_holders, me) do
            :ok -> cloned + 1
            :skip -> cloned
          end
        else
          cloned
        end
      end)
    end)
  end

  @spec clone_shard(String.t(), non_neg_integer(), MapSet.t(node()), node()) :: :ok | :skip
  defp clone_shard(chunk_hash, shard_index, online_holders, me) do
    # Estimate ~1MB per shard for quota check
    unless DiskManager.can_allocate_bytes?(1_048_576) do
      Logger.debug("RepairScheduler: skipping clone — disk quota exceeded")
      :skip
    else
      # Pick best holder by fitness score (excluding self)
      candidate =
        online_holders
        |> MapSet.delete(me)
        |> Enum.map(fn n -> {n, Fitness.score(n)} end)
        |> Enum.sort_by(fn {_, score} -> score end, :desc)
        |> List.first()

      case candidate do
        nil ->
          :skip

        {source_node, _score} ->
          case fetch_remote_shard(chunk_hash, shard_index, source_node) do
            {:ok, shard_binary} ->
              case Storage.put_shard(chunk_hash, shard_index, shard_binary) do
                :ok ->
                  ShardMap.put(chunk_hash, shard_index, me)

                  Logger.info(
                    "RepairScheduler: cloned shard #{chunk_hash}:#{shard_index} from #{source_node}"
                  )

                  :ok

                {:error, reason} ->
                  Logger.warning(
                    "RepairScheduler: failed to store cloned shard #{chunk_hash}:#{shard_index}: #{inspect(reason)}"
                  )

                  :skip
              end

            {:error, _reason} ->
              :skip
          end
      end
    end
  end

  # ── Phase 3: Missing Shard Reconstruction ───────────────────────────────

  @spec sweep_reconstruction([node()], node()) :: non_neg_integer()
  defp sweep_reconstruction(online_nodes, me) do
    budget = Config.max_reconstruct_per_sweep()
    k = Config.erasure_k()
    m = Config.erasure_m()
    total = k + m
    online_set = MapSet.new([me | online_nodes])
    referenced_chunks = build_referenced_chunks()

    referenced_chunks
    |> Enum.reduce_while(0, fn chunk_hash, reconstructed ->
      if reconstructed >= budget do
        {:halt, reconstructed}
      else
        shard_map = ShardMap.get_shards(chunk_hash)

        # Find shard indices with zero online holders
        missing_indices = find_missing_indices(shard_map, online_set, total)

        # Find shard indices with at least one online holder
        available_shards = find_available_shards(shard_map, online_set)

        if missing_indices != [] and length(available_shards) >= k do
          case reconstruct_missing(chunk_hash, missing_indices, available_shards, k, m, me) do
            {:ok, count} ->
              {:cont, reconstructed + count}

            :skip ->
              {:cont, reconstructed}
          end
        else
          {:cont, reconstructed}
        end
      end
    end)
  end

  @spec find_missing_indices(map(), MapSet.t(node()), non_neg_integer()) :: [non_neg_integer()]
  defp find_missing_indices(shard_map, online_set, total) do
    0..(total - 1)
    |> Enum.filter(fn idx ->
      case Map.get(shard_map, idx) do
        nil -> true
        %{nodes: holders} -> MapSet.disjoint?(holders, online_set)
      end
    end)
  end

  @spec find_available_shards(map(), MapSet.t(node())) ::
          [{non_neg_integer(), MapSet.t(node())}]
  defp find_available_shards(shard_map, online_set) do
    shard_map
    |> Enum.filter(fn {_idx, %{nodes: holders}} ->
      not MapSet.disjoint?(holders, online_set)
    end)
    |> Enum.map(fn {idx, %{nodes: holders}} ->
      {idx, MapSet.intersection(holders, online_set)}
    end)
  end

  @spec reconstruct_missing(
          String.t(),
          [non_neg_integer()],
          [{non_neg_integer(), MapSet.t(node())}],
          pos_integer(),
          pos_integer(),
          node()
        ) :: {:ok, non_neg_integer()} | :skip
  defp reconstruct_missing(chunk_hash, missing_indices, available_shards, k, m, me) do
    unless DiskManager.can_allocate_bytes?(1_048_576 * length(missing_indices)) do
      Logger.debug("RepairScheduler: skipping reconstruction — disk quota exceeded")
      :skip
    else
      # Get chunk meta for original_size
      case Dust.Mesh.Manifest.get_chunk_meta(chunk_hash) do
        nil ->
          Logger.warning(
            "RepairScheduler: chunk meta not found for #{chunk_hash}, skipping reconstruction"
          )

          :skip

        chunk_meta ->
          # Fetch K shards from the network
          case fetch_k_shards_for_reconstruction(chunk_hash, available_shards, k, me) do
            {:ok, fetched_shards} ->
              # Decode back to original data
              case ErasureCoding.decode(fetched_shards, chunk_meta.size, k, m) do
                {:ok, original_data} ->
                  # Re-encode to get all K+M shards
                  case ErasureCoding.encode(original_data, k, m) do
                    {:ok, all_shards} ->
                      # Store only the missing indices
                      count =
                        missing_indices
                        |> Enum.reduce(0, fn idx, acc ->
                          shard_binary = Enum.at(all_shards, idx)

                          case Storage.put_shard(chunk_hash, idx, shard_binary) do
                            :ok ->
                              ShardMap.put(chunk_hash, idx, me)

                              Logger.info(
                                "RepairScheduler: reconstructed shard #{chunk_hash}:#{idx}"
                              )

                              acc + 1

                            {:error, reason} ->
                              Logger.warning(
                                "RepairScheduler: failed to store reconstructed shard #{chunk_hash}:#{idx}: #{inspect(reason)}"
                              )

                              acc
                          end
                        end)

                      {:ok, count}

                    {:error, reason} ->
                      Logger.warning(
                        "RepairScheduler: re-encode failed for #{chunk_hash}: #{inspect(reason)}"
                      )

                      :skip
                  end

                {:error, reason} ->
                  Logger.warning(
                    "RepairScheduler: decode failed for #{chunk_hash}: #{inspect(reason)}"
                  )

                  :skip
              end

            {:error, _reason} ->
              :skip
          end
      end
    end
  end

  @spec fetch_k_shards_for_reconstruction(
          String.t(),
          [{non_neg_integer(), MapSet.t(node())}],
          pos_integer(),
          node()
        ) :: {:ok, [{non_neg_integer(), binary()}]} | {:error, term()}
  defp fetch_k_shards_for_reconstruction(chunk_hash, available_shards, k, me) do
    # Sort by fitness of best holder (descending) and take K
    ranked =
      available_shards
      |> Enum.map(fn {idx, online_holders} ->
        best_holder =
          online_holders
          |> Enum.map(fn n -> {n, Fitness.score(n)} end)
          |> Enum.sort_by(fn {_, score} -> score end, :desc)
          |> List.first()

        {idx, online_holders, best_holder}
      end)
      |> Enum.filter(fn {_, _, best} -> best != nil end)
      |> Enum.sort_by(fn {_, _, {_, score}} -> score end, :desc)
      |> Enum.take(k)

    # Fetch shards — try local first, then remote
    results =
      ranked
      |> Enum.map(fn {idx, _online_holders, {best_node, _}} ->
        if best_node == me do
          case Storage.get_shard(chunk_hash, idx) do
            {:ok, binary} -> {:ok, {idx, binary}}
            {:error, _} = err -> err
          end
        else
          case fetch_remote_shard(chunk_hash, idx, best_node) do
            {:ok, binary} -> {:ok, {idx, binary}}
            {:error, _} = err -> err
          end
        end
      end)

    successes = Enum.filter(results, &match?({:ok, _}, &1))

    if length(successes) >= k do
      {:ok, Enum.map(Enum.take(successes, k), fn {:ok, shard} -> shard end)}
    else
      Logger.warning(
        "RepairScheduler: only fetched #{length(successes)}/#{k} shards for #{chunk_hash}"
      )

      {:error, :insufficient_shards}
    end
  end

  # ── Phase 4: Stale Manifest Cleanup ─────────────────────────────────────

  @spec sweep_stale_manifest(map()) :: non_neg_integer()
  defp sweep_stale_manifest(all_registry) do
    timeout_ms = Config.stale_node_timeout_ms()
    now = DateTime.utc_now()

    # Find nodes that have been offline longer than the timeout
    stale_nodes =
      all_registry
      |> Enum.filter(fn {_node, entry} ->
        entry.status == :offline and
          DateTime.diff(now, entry.seen_at, :millisecond) > timeout_ms
      end)
      |> Enum.map(fn {node, _} -> node end)
      |> MapSet.new()

    if MapSet.size(stale_nodes) == 0 do
      0
    else
      Logger.info(
        "RepairScheduler: cleaning stale entries for nodes: #{inspect(MapSet.to_list(stale_nodes))}"
      )

      # Scan the entire ShardMap for entries referencing stale nodes
      raw_shard_map = ShardMap.all()

      raw_shard_map
      |> Enum.reduce(0, fn {key, _value}, count ->
        case String.split(key, ":") do
          [chunk_hash, shard_idx_str, node_str] ->
            node_atom = String.to_atom(node_str)

            if MapSet.member?(stale_nodes, node_atom) do
              shard_index = String.to_integer(shard_idx_str)
              ShardMap.remove_node(chunk_hash, shard_index, node_atom)
              count + 1
            else
              count
            end

          _ ->
            count
        end
      end)
    end
  end

  # ── Shared Helpers ──────────────────────────────────────────────────────

  @spec fetch_remote_shard(String.t(), non_neg_integer(), node()) ::
          {:ok, binary()} | {:error, term()}
  defp fetch_remote_shard(chunk_hash, shard_index, target_node) do
    t_start = System.monotonic_time(:millisecond)

    result =
      case :rpc.call(
             target_node,
             Dust.Storage,
             :get_shard,
             [chunk_hash, shard_index],
             @shard_fetch_timeout
           ) do
        {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
        other -> other
      end

    t_end = System.monotonic_time(:millisecond)
    latency_ms = max(t_end - t_start, 1) / 1.0

    case result do
      {:ok, shard_binary} ->
        bandwidth_mbps = byte_size(shard_binary) * 8 / latency_ms / 1_000

        Fitness.record(target_node, %Observation{
          success: true,
          latency_ms: latency_ms,
          bandwidth: bandwidth_mbps
        })

        {:ok, shard_binary}

      {:error, reason} ->
        Logger.warning(
          "RepairScheduler: shard fetch failed for #{chunk_hash}:#{shard_index} " <>
            "from #{target_node}: #{inspect(reason)}"
        )

        Fitness.record(target_node, %Observation{
          success: false,
          latency_ms: nil,
          bandwidth: nil
        })

        {:error, reason}
    end
  end

  # Builds a list of all chunk_hashes currently referenced by at least one file.
  @spec build_referenced_chunks() :: [String.t()]
  defp build_referenced_chunks do
    FileIndex.all()
    |> Enum.flat_map(fn {_file_uuid, %{chunks: chunks}} -> chunks end)
    |> Enum.uniq()
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
