defmodule Dust.Mesh.Manifest.FileIndex do
  @moduledoc """
  Distributed shared map for file manifest entries.

  Keys are UUID strings identifying a file. Values are FileIndex structs with
  `:file_meta` and `:chunks` (ordered list of chunk IDs).
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:file_meta, :chunks]
  defstruct [:file_meta, :chunks]

  @type t :: %__MODULE__{
          file_meta: Dust.Core.Crypto.FileMeta.t(),
          chunks: [String.t()]
        }

  @doc "Stores a file index entry under the given `id`."
  @spec put(String.t(), map()) :: :ok | {:error, :crdt_unavailable}
  def put(id, entry), do: crdt_put(id, entry)

  @doc "Returns the file index entry for `id`, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id), do: crdt_get(id)

  @doc "Deletes the file index entry for `id`."
  @spec delete(String.t()) :: :ok | {:error, :crdt_unavailable}
  def delete(id), do: crdt_delete(id)

  @doc "Returns all file index entries as a plain map."
  @spec all() :: map()
  def all, do: crdt_to_map()
end

defmodule Dust.Mesh.Manifest.ChunkIndex do
  @moduledoc """
  Distributed shared map for chunk metadata with reference counting.

  Keys are encrypted chunk keys (binary strings). Values are ChunkIndex structs with
  `:chunk_meta` and `:ref_count`. Duplicate puts increment the
  reference count; deletes decrement it and only remove the entry when
  the count reaches zero.
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:chunk_meta, :ref_count]
  defstruct [:chunk_meta, :ref_count]

  @type t :: %__MODULE__{
          chunk_meta: Dust.Core.Crypto.ChunkMeta.t(),
          ref_count: non_neg_integer()
        }

  @doc """
  Stores chunk metadata or increments the reference count if the key
  already exists.
  """
  @spec put(String.t(), map()) :: :ok | {:error, :crdt_unavailable}
  def put(id, entry) do
    case get(id) do
      nil ->
        crdt_put(id, entry)

      existing ->
        crdt_put(id, %{existing | ref_count: existing.ref_count + 1})
    end
  end

  @doc "Returns the chunk index entry for `id`, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id), do: crdt_get(id)

  @doc """
  Decrements the reference count for `id`. Removes the entry entirely
  when the count reaches zero. No-ops if the key does not exist.
  """
  @spec delete(String.t()) :: :ok | {:error, :crdt_unavailable}
  def delete(id) do
    case get(id) do
      nil ->
        :ok

      %{ref_count: 1} ->
        crdt_delete(id)

      existing ->
        crdt_put(id, %{existing | ref_count: existing.ref_count - 1})
    end
  end

  @doc "Returns all chunk index entries as a plain map."
  @spec all() :: map()
  def all, do: crdt_to_map()
end

defmodule Dust.Mesh.Manifest.ShardMap do
  @moduledoc """
  Distributed shared map for shard placement.

  Tracks which nodes hold each erasure-coded shard for a given chunk.
  Keys are composite strings `"{chunk_hash}:{shard_index}"`.  Values
  are `ShardMap` structs with `:nodes` — a `MapSet` of node atoms,
  allowing multiple nodes to replicate the same shard.
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:nodes]
  defstruct [:nodes]

  @type t :: %__MODULE__{
          nodes: MapSet.t(node())
        }

  @doc """
  Record that `node` holds shard `shard_index` for `chunk_hash`.

  If the shard already has an entry, the node is added to the existing
  set. Otherwise a new entry is created.
  """
  @spec put(String.t(), non_neg_integer(), node()) :: :ok | {:error, :crdt_unavailable}
  def put(chunk_hash, shard_index, node)
      when is_binary(chunk_hash) and is_integer(shard_index) and is_atom(node) do
    k = key(chunk_hash, shard_index)

    entry =
      case crdt_get(k) do
        nil -> %__MODULE__{nodes: MapSet.new([node])}
        existing -> %{existing | nodes: MapSet.put(existing.nodes, node)}
      end

    crdt_put(k, entry)
  end

  @doc """
  Removes a single node from a shard entry.

  If the node set becomes empty after removal, the entry is deleted.
  """
  @spec remove_node(String.t(), non_neg_integer(), node()) :: :ok | {:error, :crdt_unavailable}
  def remove_node(chunk_hash, shard_index, node)
      when is_binary(chunk_hash) and is_integer(shard_index) and is_atom(node) do
    k = key(chunk_hash, shard_index)

    case crdt_get(k) do
      nil ->
        :ok

      existing ->
        new_nodes = MapSet.delete(existing.nodes, node)

        if MapSet.size(new_nodes) == 0 do
          crdt_delete(k)
        else
          crdt_put(k, %{existing | nodes: new_nodes})
        end
    end
  end

  @doc """
  Returns a map of `%{shard_index => %ShardMap{}}` for all shards of
  the given `chunk_hash`.
  """
  @spec get_shards(String.t()) :: %{non_neg_integer() => t()}
  def get_shards(chunk_hash) when is_binary(chunk_hash) do
    prefix = chunk_hash <> ":"

    crdt_to_map()
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)
    |> Map.new(fn {k, v} ->
      shard_index =
        k
        |> String.replace_prefix(prefix, "")
        |> String.to_integer()

      {shard_index, v}
    end)
  end

  @doc "Removes all shard entries for `chunk_hash` (indices 0..total_shards-1)."
  @spec delete_shards(String.t(), non_neg_integer()) :: :ok
  def delete_shards(chunk_hash, total_shards)
      when is_binary(chunk_hash) and is_integer(total_shards) do
    for i <- 0..(total_shards - 1)//1 do
      crdt_delete(key(chunk_hash, i))
    end

    :ok
  end

  @doc "Removes a single shard entry entirely (all nodes)."
  @spec delete(String.t(), non_neg_integer()) :: :ok | {:error, :crdt_unavailable}
  def delete(chunk_hash, shard_index)
      when is_binary(chunk_hash) and is_integer(shard_index) do
    crdt_delete(key(chunk_hash, shard_index))
  end

  @doc "Returns the full shard map as a plain Elixir map."
  @spec all() :: map()
  def all, do: crdt_to_map()

  defp key(chunk_hash, shard_index), do: "#{chunk_hash}:#{shard_index}"
end

defmodule Dust.Mesh.Manifest do
  @moduledoc """
  Content-addressable manifest for encrypted file and chunk metadata.

  Maintains three distributed CRDT-backed indices:

    - `FileIndex`  — maps file UUIDs to their encrypted file key and
                     ordered list of chunk IDs.

    - `ChunkIndex` — maps chunk IDs (hashes) to their
                     content hash, size, and a reference count for
                     deduplication across files.

    - `ShardMap`   — maps `"{chunk_hash}:{shard_index}"` to the node
                     holding that erasure-coded shard.

  All indices are backed by `Dust.Mesh.SharedMap` and sync automatically
  across all connected nodes via DeltaCrdt.
  """

  alias Dust.Mesh.Manifest.{FileIndex, ChunkIndex, ShardMap}
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  # ── Types ───────────────────────────────────────────────────────────────────

  @type file_index :: FileIndex.t()
  @type chunk_index :: ChunkIndex.t()

  # ── Manifest API ───────────────────────────────────────────────────────────

  @doc """
  Indexes a file and all of its chunks into the manifest.

  Each chunk from `chunk_meta_stream` is stored in the `ChunkIndex` (with
  deduplication via reference counting), and the resulting chunk ID list is
  persisted alongside the file's encrypted key in the `FileIndex`.
  """
  @spec store_file_stream(String.t(), FileMeta.t(), Enumerable.t(ChunkMeta.t())) ::
          :ok | {:error, :crdt_unavailable}
  def store_file_stream(file_uuid, %FileMeta{} = file_meta, chunk_meta_stream)
      when is_binary(file_uuid) do
    result =
      Enum.reduce_while(chunk_meta_stream, {:ok, []}, fn chunk_meta, {:ok, acc} ->
        case store_chunk(chunk_meta) do
          {:ok, chunk_id} -> {:cont, {:ok, [chunk_id | acc]}}
          {:error, :crdt_unavailable} -> {:halt, {:error, :crdt_unavailable}}
        end
      end)

    case result do
      {:error, :crdt_unavailable} ->
        {:error, :crdt_unavailable}

      {:ok, reversed_ids} ->
        chunk_id_list = Enum.reverse(reversed_ids)

        file_index = %FileIndex{
          file_meta: file_meta,
          chunks: chunk_id_list
        }

        case FileIndex.put(file_uuid, file_index) do
          {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
          :ok -> :ok
        end
    end
  end

  @doc """
  Records shard placements for a chunk.

  `shard_placements` is a list of `{shard_index, node}` tuples indicating
  which node holds each erasure-coded shard.
  """
  @spec store_shards(String.t(), [{non_neg_integer(), node()}]) ::
          :ok | {:error, :crdt_unavailable}
  def store_shards(chunk_hash, shard_placements)
      when is_binary(chunk_hash) and is_list(shard_placements) do
    Enum.reduce_while(shard_placements, :ok, fn {shard_index, node}, :ok ->
      case ShardMap.put(chunk_hash, shard_index, node) do
        :ok -> {:cont, :ok}
        {:error, :crdt_unavailable} -> {:halt, {:error, :crdt_unavailable}}
      end
    end)
  end

  @doc """
  Returns shard locations for a chunk.

  Returns `%{shard_index => %ShardMap{nodes: MapSet}}` for all known
  shards of the given chunk hash.
  """
  @spec get_shard_locations(String.t()) :: %{non_neg_integer() => ShardMap.t()}
  def get_shard_locations(chunk_hash) when is_binary(chunk_hash) do
    ShardMap.get_shards(chunk_hash)
  end

  @doc """
  Removes a file and decrements the reference count for each of its chunks.

  Chunks whose reference count reaches zero are deleted from the `ChunkIndex`.
  Shard placement entries are also cleaned up for fully dereferenced chunks.
  `total_shards` is the number of erasure-coded shards per chunk (K + M).
  Returns `{:error, :not_found}` if the file UUID is not in the index.
  """
  @spec remove_file(String.t(), non_neg_integer()) :: :ok | {:error, :not_found}
  def remove_file(file_uuid, total_shards \\ 6) when is_binary(file_uuid) do
    case FileIndex.get(file_uuid) do
      nil ->
        {:error, :not_found}

      %{chunks: chunks} ->
        # Delete chunks first — if we crash mid-way, the file index still
        # exists and cleanup can be retried. The reverse order (delete index
        # first) would leave orphaned chunk entries with no way to find them.
        Enum.each(chunks, fn chunk_hash ->
          ChunkIndex.delete(chunk_hash)

          # Clean up shard entries if chunk is fully dereferenced
          if ChunkIndex.get(chunk_hash) == nil do
            ShardMap.delete_shards(chunk_hash, total_shards)
          end
        end)

        FileIndex.delete(file_uuid)
        :ok
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  @spec store_chunk(ChunkMeta.t()) :: {:ok, String.t()} | {:error, :crdt_unavailable}
  defp store_chunk(%ChunkMeta{} = chunk_meta) do
    index = %ChunkIndex{
      chunk_meta: chunk_meta,
      ref_count: 1
    }

    key = chunk_meta.hash

    case ChunkIndex.put(key, index) do
      {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
      :ok -> {:ok, key}
    end
  end
end
