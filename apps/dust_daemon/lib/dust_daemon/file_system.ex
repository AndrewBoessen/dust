defmodule Dust.Daemon.FileSystem do
  @moduledoc """
  Public high-level facade for file operations across the Dust network.

  Orchestrates cryptography (Core), indexing (Mesh), persistence (Storage),
  and peer distribution (Bridge).
  """

  alias Dust.Core.{Crypto, Packer, Unpacker, ErasureCoding}
  alias Dust.Core.Fitness
  alias Dust.Core.Fitness.Observation
  alias Dust.Mesh.{FileSystem, Manifest}
  alias Dust.Mesh.NodeRegistry
  alias Dust.Storage
  alias Dust.Utilities.Config

  require Logger

  # PubSub topic for download progress notifications
  @download_topic :download_progress

  # PubSub topic for upload progress notifications
  @upload_topic :upload_progress

  # Maximum per-node retry attempts before falling back to next node
  @max_node_retries 2

  # Timeout for a single shard fetch task (ms)
  @shard_fetch_timeout 30_000

  # ── PubSub ─────────────────────────────────────────────────────────────

  @doc """
  Subscribe the calling process to download progress notifications.

  Messages arrive as `{:download_progress, file_uuid, chunk_index, total_chunks}`.
  """
  @spec subscribe_download_progress() :: {:ok, pid()} | {:error, term()}
  def subscribe_download_progress do
    Registry.register(Dust.Daemon.Registry, @download_topic, [])
  end

  defp broadcast_download_progress(file_uuid, chunk_index, total_chunks) do
    Registry.dispatch(Dust.Daemon.Registry, @download_topic, fn subscribers ->
      Enum.each(subscribers, fn {pid, _} ->
        send(pid, {:download_progress, file_uuid, chunk_index, total_chunks})
      end)
    end)
  end

  @doc """
  Subscribe the calling process to upload progress notifications.

  Messages arrive as `{:upload_progress, file_uuid, chunk_index, total_chunks}`.
  """
  @spec subscribe_upload_progress() :: {:ok, pid()} | {:error, term()}
  def subscribe_upload_progress do
    Registry.register(Dust.Daemon.Registry, @upload_topic, [])
  end

  defp broadcast_upload_progress(file_uuid, chunk_index, total_chunks) do
    Registry.dispatch(Dust.Daemon.Registry, @upload_topic, fn subscribers ->
      Enum.each(subscribers, fn {pid, _} ->
        send(pid, {:upload_progress, file_uuid, chunk_index, total_chunks})
      end)
    end)
  end

  # ── Upload ─────────────────────────────────────────────────────────────

  @doc """
  Uploads a local file to the Dust storage network, streaming it from disk.

  The file is read in 4 MB chunks and processed **sequentially** to avoid
  holding the entire file in memory. Each chunk is encrypted, erasure-coded
  into K+M shards, and stored locally via `Dust.Storage`. Shard placements
  and chunk metadata are committed to the distributed manifest.

  Upload progress is broadcast via PubSub — subscribe with
  `subscribe_upload_progress/0` to receive
  `{:upload_progress, file_uuid, chunk_index, total_chunks}` messages.

  If an unrecoverable fault occurs at any stage, a cleanup routine rolls
  back partial filesystem entries and purges orphaned shards.

  Returns `{:ok, file_uuid}` on success.
  """
  @spec upload(Path.t(), FileSystem.uuid(), String.t()) ::
          {:ok, FileSystem.uuid()}
          | {:error,
             File.posix()
             | :file_store_failed
             | :crdt_unavailable
             | :dir_not_found
             | :insufficient_disk_quota}
  def upload(local_file_path, dest_dir_id, file_name) do
    with :ok <- check_upload_quota(local_file_path),
         {:ok, file_meta, stream} <- Packer.process_file_stream(local_file_path),
         {:ok, size} <- get_file_size(local_file_path),
         {:ok, checksum} <- get_file_checksum(local_file_path),
         mime = get_mime_type(local_file_path),
         mapped_meta = %{size: size, checksum: checksum, mime: mime},
         {:ok, file_uuid} <- FileSystem.put_file(dest_dir_id, file_name, mapped_meta) do
      upload_chunks(file_uuid, file_meta, stream)
    end
  end

  # Estimates the total local storage needed for the erasure-coded shards
  # and checks it against the disk quota. Erasure coding expands the
  # original file by a factor of (K+M)/K.
  @spec check_upload_quota(Path.t()) :: :ok | {:error, :insufficient_disk_quota | File.posix()}
  defp check_upload_quota(local_file_path) do
    case File.stat(local_file_path) do
      {:ok, %File.Stat{size: file_size}} ->
        k = Config.erasure_k()
        total = Config.total_shards()
        # Each chunk produces total shards, each ≈ chunk_size/k bytes
        estimated_bytes = ceil(file_size * total / k)

        if Dust.Daemon.DiskManager.can_allocate_bytes?(estimated_bytes) do
          :ok
        else
          {:error, :insufficient_disk_quota}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_file_checksum(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        hash =
          IO.stream(file, 2048)
          |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
            :crypto.hash_update(acc, chunk)
          end)
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        File.close(file)
        {:ok, hash}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_mime_type(path) do
    case System.cmd("file", ["-b", "--mime-type", path]) do
      {mime, 0} -> String.trim(mime)
      _ -> "application/octet-stream"
    end
  end

  # ── Upload Chunk Processing ────────────────────────────────────────────

  # Streams through all chunks, encoding and storing each one sequentially.
  # On success, commits the full file manifest. On failure, cleans up.
  defp upload_chunks(file_uuid, file_meta, stream) do
    # Materialize the stream to get total count for progress reporting
    chunks = Enum.to_list(stream)
    total_chunks = length(chunks)

    result =
      chunks
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {{chunk_meta, binary}, idx}, {:ok, acc} ->
        case encode_and_store_chunk(chunk_meta, binary) do
          {:ok, stored_meta} ->
            broadcast_upload_progress(file_uuid, idx + 1, total_chunks)
            {:cont, {:ok, [stored_meta | acc]}}

          {:error, :shard_storage_failed} ->
            Logger.error("Upload: shard storage failed for chunk #{chunk_meta.hash}")
            {:halt, {:error, :chunk_store_failed, [chunk_meta | acc]}}

          {:error, :crdt_unavailable} ->
            Logger.error(
              "Upload: CRDT unavailable while storing shards for chunk #{chunk_meta.hash}"
            )

            {:halt, {:error, :crdt_unavailable, [chunk_meta | acc]}}
        end
      end)

    finalize_upload(file_uuid, file_meta, result)
  end

  # Encodes a single chunk into shards, stores them locally, and records
  # shard placements in the manifest.
  defp encode_and_store_chunk(%Crypto.ChunkMeta{hash: chunk_hash} = chunk_meta, binary) do
    k = Config.erasure_k()
    m = Config.erasure_m()

    {:ok, shards} = ErasureCoding.encode(binary, k, m)

    case store_shards_locally(chunk_hash, shards) do
      {:ok, shard_placements} ->
        case Manifest.store_shards(chunk_hash, shard_placements) do
          :ok -> {:ok, chunk_meta}
          {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
        end

      {:error, _} = err ->
        err
    end
  end

  # Persists each shard binary to local storage, returning a list of
  # `{shard_index, node()}` placement tuples.
  defp store_shards_locally(chunk_hash, shards) do
    shards
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {shard_binary, shard_index}, {:ok, acc} ->
      case Storage.put_shard(chunk_hash, shard_index, shard_binary) do
        :ok ->
          {:cont, {:ok, [{shard_index, node()} | acc]}}

        {:error, reason} ->
          Logger.error(
            "Upload: failed to store shard #{chunk_hash}:#{shard_index}: #{inspect(reason)}"
          )

          {:halt, {:error, :shard_storage_failed}}
      end
    end)
  end

  # Commits the completed chunk list to the manifest, or cleans up on failure.
  defp finalize_upload(file_uuid, file_meta, result) do
    case result do
      {:ok, meta_list_reversed} ->
        meta_list = Enum.reverse(meta_list_reversed)

        case Manifest.store_file_stream(file_uuid, file_meta, meta_list) do
          :ok ->
            {:ok, file_uuid}

          {:error, reason} = err ->
            Logger.error("Upload: failed to commit manifest for #{file_uuid}: #{inspect(reason)}")
            cleanup_upload(file_uuid, meta_list)
            err
        end

      {:error, :chunk_store_failed, attempted_meta_list} ->
        cleanup_upload(file_uuid, attempted_meta_list)
        {:error, :file_store_failed}

      {:error, :crdt_unavailable, attempted_meta_list} ->
        cleanup_upload(file_uuid, attempted_meta_list)
        {:error, :crdt_unavailable}
    end
  end

  defp cleanup_upload(file_uuid, meta_list) do
    total_shards = Config.total_shards()

    FileSystem.rm_file(file_uuid)

    Enum.each(meta_list, fn %Crypto.ChunkMeta{hash: chunk_hash} ->
      Storage.delete_chunk_shards(chunk_hash, total_shards)
      Manifest.ShardMap.delete_shards(chunk_hash, total_shards)
    end)
  end

  # ── Download ───────────────────────────────────────────────────────────

  @doc """
  Downloads a file from the Dust network, streaming it to `local_dest_path`.

  Chunks are processed **sequentially** to avoid holding the entire file in
  memory. Shards within each chunk are fetched **asynchronously** from peer
  nodes, ranked by the `Dust.Core.Fitness` module. Downloading stops after
  receiving K shards per chunk (erasure coding reconstruction threshold).

  Download progress is broadcast via PubSub — subscribe with
  `subscribe_download_progress/0` to receive `{:download_progress, file_uuid, idx, total}`
  messages.

  Returns `{:ok, local_dest_path}` on success.
  """
  @spec download(String.t(), Path.t()) ::
          {:ok, Path.t()}
          | {:error,
             :file_not_found
             | :integrity_check_failed
             | :insufficient_shards
             | :chunk_meta_not_found
             | :decode_failed
             | term()}
  def download(file_uuid, local_dest_path) do
    with {:ok, chunk_hashes, file_meta} <- Manifest.get_file(file_uuid),
         {:ok, file_key} <- Crypto.decrypt_file_key(file_meta) do
      stream_chunks_to_file(file_uuid, chunk_hashes, file_key, local_dest_path)
    end
  end

  # ── Chunk Streaming ────────────────────────────────────────────────────

  defp stream_chunks_to_file(file_uuid, chunk_hashes, file_key, dest_path) do
    total_chunks = length(chunk_hashes)
    file = File.open!(dest_path, [:write, :binary])

    try do
      chunk_hashes
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {chunk_hash, idx}, :ok ->
        case download_and_write_chunk(chunk_hash, file_key, file) do
          :ok ->
            broadcast_download_progress(file_uuid, idx + 1, total_chunks)
            {:cont, :ok}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        :ok -> {:ok, dest_path}
        {:error, _} = err -> err
      end
    after
      File.close(file)
    end
  end

  defp download_and_write_chunk(chunk_hash, file_key, file) do
    k = Config.erasure_k()
    m = Config.erasure_m()

    case Manifest.get_chunk_meta(chunk_hash) do
      nil ->
        {:error, :chunk_meta_not_found}

      %Crypto.ChunkMeta{} = chunk_meta ->
        shard_locations = Manifest.get_shard_locations(chunk_hash)

        case fetch_k_shards(chunk_hash, shard_locations, k, m) do
          {:ok, shards} ->
            with {:ok, encrypted_payload} <-
                   ErasureCoding.decode(shards, chunk_meta.size, k, m),
                 {:ok, plaintext} <-
                   Unpacker.unpack_chunk(encrypted_payload, chunk_meta, file_key) do
              IO.binwrite(file, plaintext)
              :ok
            end

          {:error, _} = err ->
            err
        end
    end
  end

  # ── Shard Fetching Engine ──────────────────────────────────────────────

  @doc false
  # Fetches exactly K shards using fitness-ranked nodes with per-node retry
  # and fallback to slower nodes / parity shards.
  defp fetch_k_shards(chunk_hash, shard_locations, k, _m) do
    # Build candidate map: %{shard_index => [{node, score}]} sorted best→worst
    candidates = build_fetch_plan(shard_locations)

    if map_size(candidates) < k do
      {:error, :insufficient_shards}
    else
      # Take top-K shard indices by their best node's score
      ranked_shards =
        candidates
        |> Enum.map(fn {shard_idx, [{_node, score} | _]} -> {shard_idx, score} end)
        |> Enum.sort_by(fn {_, score} -> score end, :desc)

      {initial_shards, reserve_shards} = Enum.split(ranked_shards, k)

      # Launch initial batch of K tasks
      initial_tasks =
        Enum.map(initial_shards, fn {shard_idx, _score} ->
          [{best_node, _} | rest_nodes] = Map.fetch!(candidates, shard_idx)
          launch_shard_task(chunk_hash, shard_idx, best_node, rest_nodes)
        end)

      reserve_indices = Enum.map(reserve_shards, fn {idx, _} -> idx end)
      collect_k_shards(initial_tasks, reserve_indices, candidates, chunk_hash, [], k)
    end
  end

  # Build a map of %{shard_index => [{node, score}, ...]} for each shard,
  # with nodes sorted by fitness score descending and filtered to online only.
  defp build_fetch_plan(shard_locations) do
    online = MapSet.new(NodeRegistry.online_nodes() ++ [node()])

    shard_locations
    |> Enum.reduce(%{}, fn {shard_index, %{nodes: nodes}}, acc ->
      ranked_nodes =
        nodes
        |> Enum.filter(&MapSet.member?(online, &1))
        |> Enum.map(fn n -> {n, Fitness.score(n)} end)
        |> Enum.sort_by(fn {_, score} -> score end, :desc)

      case ranked_nodes do
        [] -> acc
        _ -> Map.put(acc, shard_index, ranked_nodes)
      end
    end)
  end

  # Launch a task that attempts to fetch a shard, with retry info attached
  defp launch_shard_task(chunk_hash, shard_index, node, remaining_nodes) do
    task =
      Task.async(fn ->
        fetch_single_shard(chunk_hash, shard_index, node)
      end)

    {task, shard_index, remaining_nodes, @max_node_retries - 1}
  end

  # Collect loop: gather K successful shards, retrying/replacing as needed
  defp collect_k_shards(_tasks, _reserves, _candidates, _chunk_hash, collected, k)
       when length(collected) >= k do
    {:ok, Enum.take(collected, k)}
  end

  defp collect_k_shards([], _reserves, _candidates, _chunk_hash, collected, k)
       when length(collected) < k do
    Logger.error("Download: only collected #{length(collected)}/#{k} shards, giving up")
    {:error, :insufficient_shards}
  end

  defp collect_k_shards(tasks, reserves, candidates, chunk_hash, collected, k) do
    task_refs = Enum.map(tasks, fn {task, _, _, _} -> task end)
    results = Task.yield_many(task_refs, @shard_fetch_timeout)

    {new_collected, retry_tasks, remaining_reserves} =
      process_results(results, tasks, reserves, candidates, chunk_hash, collected)

    # Shut down any tasks that timed out and were not handled
    Enum.each(results, fn
      {task, nil} -> Task.shutdown(task, :brutal_kill)
      _ -> :ok
    end)

    if length(new_collected) >= k do
      # Shut down any remaining retry tasks
      Enum.each(retry_tasks, fn {task, _, _, _} -> Task.shutdown(task, :brutal_kill) end)
      {:ok, Enum.take(new_collected, k)}
    else
      collect_k_shards(retry_tasks, remaining_reserves, candidates, chunk_hash, new_collected, k)
    end
  end

  # Process yield_many results, building retry tasks for failures
  defp process_results(results, tasks, reserves, candidates, chunk_hash, collected) do
    # Build a map from task ref to our metadata
    task_meta =
      Map.new(tasks, fn {task, shard_idx, remaining, retries} ->
        {task.ref, {shard_idx, remaining, retries}}
      end)

    {new_collected, failed_shards} =
      Enum.reduce(results, {collected, []}, fn {task, result}, {coll_acc, fail_acc} ->
        {shard_idx, remaining_nodes, retries_left} = Map.fetch!(task_meta, task.ref)

        case result do
          {:ok, {:ok, {idx, binary}}} ->
            {[{idx, binary} | coll_acc], fail_acc}

          _ ->
            {coll_acc, [{shard_idx, remaining_nodes, retries_left} | fail_acc]}
        end
      end)

    # For each failed shard, try the next node or fall back to a reserve shard
    {retry_tasks, remaining_reserves} =
      Enum.reduce(failed_shards, {[], reserves}, fn
        {shard_idx, [{next_node, _} | rest], retries_left}, {task_acc, res_acc}
        when retries_left > 0 ->
          # Retry with the next-ranked node for the same shard
          task = launch_shard_task(chunk_hash, shard_idx, next_node, rest)
          {[task | task_acc], res_acc}

        {_shard_idx, _remaining, _retries}, {task_acc, [reserve_idx | rest_reserves]} ->
          # All nodes exhausted for this shard — try a reserve (parity) shard
          case Map.get(candidates, reserve_idx) do
            [{best_node, _} | rest_nodes] ->
              task = launch_shard_task(chunk_hash, reserve_idx, best_node, rest_nodes)
              {[task | task_acc], rest_reserves}

            _ ->
              {task_acc, rest_reserves}
          end

        {_shard_idx, _remaining, _retries}, {task_acc, []} ->
          # No reserves left
          {task_acc, []}
      end)

    {new_collected, retry_tasks, remaining_reserves}
  end

  # ── Single Shard Fetch ─────────────────────────────────────────────────

  defp fetch_single_shard(chunk_hash, shard_index, target_node) do
    t_start = System.monotonic_time(:millisecond)

    result =
      if target_node == node() do
        # Local fast path — no RPC overhead
        Storage.get_shard(chunk_hash, shard_index)
      else
        case :rpc.call(target_node, Dust.Storage, :get_shard, [chunk_hash, shard_index]) do
          {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
          other -> other
        end
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

        {:ok, {shard_index, shard_binary}}

      {:error, reason} ->
        Logger.warning(
          "Download: shard fetch failed for #{chunk_hash}:#{shard_index} " <>
            "from #{target_node}: #{inspect(reason)}"
        )

        Fitness.record(target_node, %Observation{
          success: false,
          latency_ms: nil,
          bandwidth: nil
        })

        {:error, :shard_fetch_failed}
    end
  end
end
