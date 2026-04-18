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
  Distributed shared map for chunk metadata.

  Keys are encrypted chunk keys (binary strings). Values are ChunkIndex structs with
  `:chunk_meta`. Because overlapping identical files have deterministic chunk meta,
  concurrent inserts simply overwrite idempotently (zero read-modify-write).
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:chunk_meta]
  defstruct [:chunk_meta]

  @type t :: %__MODULE__{
          chunk_meta: Dust.Core.Crypto.ChunkMeta.t()
        }

  @doc """
  Stores chunk metadata unconditionally, merging efficiently in LWW.
  """
  @spec put(String.t(), map()) :: :ok | {:error, :crdt_unavailable}
  def put(id, entry) do
    crdt_put(id, entry)
  end

  @doc "Returns the chunk index entry for `id`, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id), do: crdt_get(id)

  @doc """
  Deletes the chunk instance entirely.
  """
  @spec delete(String.t()) :: :ok | {:error, :crdt_unavailable}
  def delete(id) do
    crdt_delete(id)
  end

  @doc "Returns all chunk index entries as a plain map."
  @spec all() :: map()
  def all, do: crdt_to_map()
end

defmodule Dust.Mesh.Manifest.ShardMap do
  @moduledoc """
  Distributed shared map for shard placement.

  Tracks which nodes hold each erasure-coded shard for a given chunk.
  Keys are compound strings `"{chunk_hash}:{shard_index}:{node}"` to guarantee
  conflict-free Last-Writer-Wins map writes under concurrency.

  When queried, dynamically reconstitutes a map of `%ShardMap{}` structs for API parity.
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:nodes]
  defstruct [:nodes]

  @type t :: %__MODULE__{
          nodes: MapSet.t(node())
        }

  @doc """
  Record that `node` holds shard `shard_index` for `chunk_hash`.
  """
  @spec put(String.t(), non_neg_integer(), node()) :: :ok | {:error, :crdt_unavailable}
  def put(chunk_hash, shard_index, node)
      when is_binary(chunk_hash) and is_integer(shard_index) and is_atom(node) do
    k = key(chunk_hash, shard_index, node)
    crdt_put(k, true)
  end

  @doc """
  Removes a single node from a shard entry by deleting its specific key.
  """
  @spec remove_node(String.t(), non_neg_integer(), node()) :: :ok | {:error, :crdt_unavailable}
  def remove_node(chunk_hash, shard_index, node)
      when is_binary(chunk_hash) and is_integer(shard_index) and is_atom(node) do
    k = key(chunk_hash, shard_index, node)
    crdt_delete(k)
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
    |> Enum.reduce(%{}, fn {k, _v}, acc ->
      [_, shard_idx_str, node_str] = String.split(k, ":")
      shard_index = String.to_integer(shard_idx_str)
      node = String.to_atom(node_str)

      Map.update(acc, shard_index, %__MODULE__{nodes: MapSet.new([node])}, fn existing ->
        %{existing | nodes: MapSet.put(existing.nodes, node)}
      end)
    end)
  end

  @doc "Removes all shard entries spanning all nodes for `chunk_hash`."
  @spec delete_shards(String.t(), non_neg_integer()) :: :ok
  def delete_shards(chunk_hash, _total_shards)
      when is_binary(chunk_hash) do
    prefix = chunk_hash <> ":"

    crdt_to_map()
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)
    |> Enum.each(fn {k, _v} -> crdt_delete(k) end)

    :ok
  end

  @doc "Removes a single shard index entirely (all nodes)."
  @spec delete(String.t(), non_neg_integer()) :: :ok | {:error, :crdt_unavailable}
  def delete(chunk_hash, shard_index)
      when is_binary(chunk_hash) and is_integer(shard_index) do
    prefix = "#{chunk_hash}:#{shard_index}:"

    crdt_to_map()
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)
    |> Enum.each(fn {k, _v} -> crdt_delete(k) end)

    :ok
  end

  @doc """
  Returns a grouped map of all shards: `%{chunk_hash => %{shard_index => %ShardMap{nodes: ...}}}`.
  Avoids repeated crdt_to_map iterations.
  """
  @spec all_grouped() :: %{String.t() => %{non_neg_integer() => t()}}
  def all_grouped do
    crdt_to_map()
    |> Enum.reduce(%{}, fn {k, _v}, acc ->
      case String.split(k, ":") do
        [chunk_hash, shard_idx_str, node_str] ->
          shard_index = String.to_integer(shard_idx_str)
          node = String.to_atom(node_str)

          Map.update(
            acc,
            chunk_hash,
            %{shard_index => %__MODULE__{nodes: MapSet.new([node])}},
            fn chunk_map ->
              Map.update(
                chunk_map,
                shard_index,
                %__MODULE__{nodes: MapSet.new([node])},
                fn existing ->
                  %{existing | nodes: MapSet.put(existing.nodes, node)}
                end
              )
            end
          )

        _ ->
          acc
      end
    end)
  end

  @doc "Returns the full shard map as a plain Elixir map (for raw debugging)."
  @spec all() :: map()
  def all, do: crdt_to_map()

  defp key(chunk_hash, shard_index, node), do: "#{chunk_hash}:#{shard_index}:#{node}"
end

defmodule Dust.Mesh.Manifest do
  @moduledoc """
  Content-addressable manifest for encrypted file and chunk metadata.

  Maintains three distributed CRDT-backed indices:

    - `FileIndex`  — maps file UUIDs to their encrypted file key and
                     ordered list of chunk IDs.

    - `ChunkIndex` — maps chunk IDs (hashes) to their content hash and size.
                     Duplicate entries naturally overwrite (Add-Wins LWW).

    - `ShardMap`   — dynamic shard-holding registry utilizing flattened keys
                     (node+shard+hash) to strictly prevent MapSet overwrites.

  All indices are backed by `Dust.Mesh.SharedMap` and sync automatically
  across all connected nodes via DeltaCrdt.
  """

  alias Dust.Mesh.Manifest.{FileIndex, ChunkIndex, ShardMap}
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  # ── Types ───────────────────────────────────────────────────────────────────

  @type file_index :: FileIndex.t()
  @type chunk_index :: ChunkIndex.t()
  @type shard_map :: ShardMap.t()

  # ── Manifest API ───────────────────────────────────────────────────────────

  @doc """
  Indexes a file and all of its chunks into the manifest.

  Each chunk from `chunk_meta_stream` is stored in the `ChunkIndex`, and the
  resulting chunk ID list is persisted alongside the file's encrypted key in `FileIndex`.
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
  Returns all shard locations for all chunks in the entire cluster as a
  grouped map: `%{chunk_hash => %{shard_index => %ShardMap{nodes: MapSet}}}`.
  """
  @spec get_all_shard_locations() :: %{String.t() => %{non_neg_integer() => ShardMap.t()}}
  def get_all_shard_locations do
    ShardMap.all_grouped()
  end

  @doc """
  Returns the chunks making up the file and file metadata

  Returns `{:ok, [String.t()], Dust.Core.Crypto.FileMeta.t()}` where each element is a chunk hash or error if file uuid not found
  """
  @spec get_file(String.t()) ::
          {:ok, [String.t()], Dust.Core.Crypto.FileMeta.t()} | {:error, :file_not_found}
  def get_file(file_uuid) when is_binary(file_uuid) do
    case FileIndex.get(file_uuid) do
      %FileIndex{chunks: chunks, file_meta: meta} ->
        {:ok, chunks, meta}

      nil ->
        {:error, :file_not_found}
    end
  end

  @doc """
  Removes a file and verifies if its chunks are orphaned.

  If no other surviving files reference those chunks in the FileIndex,
  the chunks (and corresponding ShardMap tracker paths) are expunged.
  """
  @spec remove_file(String.t(), non_neg_integer()) :: :ok | {:error, :not_found}
  def remove_file(file_uuid, total_shards \\ 6) when is_binary(file_uuid) do
    case FileIndex.get(file_uuid) do
      nil ->
        {:error, :not_found}

      %{chunks: chunks} ->
        # Drop the file reference first
        FileIndex.delete(file_uuid)

        # Collect global references remaining across the system
        live_chunks =
          FileIndex.all()
          |> Enum.flat_map(fn {_id, f} -> f.chunks end)
          |> MapSet.new()

        Enum.each(chunks, fn chunk_hash ->
          if not MapSet.member?(live_chunks, chunk_hash) do
            ChunkIndex.delete(chunk_hash)
            ShardMap.delete_shards(chunk_hash, total_shards)
          end
        end)

        :ok
    end
  end

  @doc """
  Returns the `ChunkMeta` for a given chunk hash, or `nil` if not found.
  """
  @spec get_chunk_meta(String.t()) :: ChunkMeta.t() | nil
  def get_chunk_meta(chunk_hash) when is_binary(chunk_hash) do
    case ChunkIndex.get(chunk_hash) do
      %ChunkIndex{chunk_meta: meta} -> meta
      nil -> nil
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  @spec store_chunk(ChunkMeta.t()) :: {:ok, String.t()} | {:error, :crdt_unavailable}
  defp store_chunk(%ChunkMeta{} = chunk_meta) do
    index = %ChunkIndex{
      chunk_meta: chunk_meta
    }

    key = chunk_meta.hash

    case ChunkIndex.put(key, index) do
      {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
      :ok -> {:ok, key}
    end
  end
end
