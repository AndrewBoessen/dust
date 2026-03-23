defmodule Dust.Mesh.Manifest do
  @moduledoc """
  Content-addressable manifest for encrypted file and chunk metadata.

  Maintains two distributed CRDT-backed indices:

    - `FileIndex`  — maps file UUIDs to their encrypted file key and
                     ordered list of chunk IDs.

    - `ChunkIndex` — maps chunk IDs (encrypted chunk keys) to their
                     content hash, size, and a reference count for
                     deduplication across files.

  Both indices are backed by `Dust.Mesh.SharedMap` and sync automatically
  across all connected nodes via DeltaCrdt.
  """

  alias Dust.Mesh.Manifest.{FileIndex, ChunkIndex}
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  # ── Types ───────────────────────────────────────────────────────────────────

  @type file_index :: %{
          encrypted_file_key: Dust.Core.Crypto.encrypted_key(),
          chunks: [String.t()]
        }

  @type chunk_index :: %{
          encrypted_chunk_key: Dust.Core.Crypto.encrypted_key(),
          hash: String.t(),
          size: non_neg_integer(),
          ref_count: non_neg_integer()
        }

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

        file_index = %{
          encrypted_file_key: file_meta.encrypted_file_key,
          chunks: chunk_id_list
        }

        case FileIndex.put(file_uuid, file_index) do
          {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
          :ok -> :ok
        end
    end
  end

  @doc """
  Removes a file and decrements the reference count for each of its chunks.

  Chunks whose reference count reaches zero are deleted from the `ChunkIndex`.
  Returns `{:error, :not_found}` if the file UUID is not in the index.
  """
  @spec remove_file(String.t()) :: :ok | {:error, :not_found}
  def remove_file(file_uuid) when is_binary(file_uuid) do
    case FileIndex.get(file_uuid) do
      nil ->
        {:error, :not_found}

      %{chunks: chunks} ->
        # Delete chunks first — if we crash mid-way, the file index still
        # exists and cleanup can be retried. The reverse order (delete index
        # first) would leave orphaned chunk entries with no way to find them.
        Enum.each(chunks, fn chunk -> ChunkIndex.delete(chunk) end)
        FileIndex.delete(file_uuid)
        :ok
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  @spec store_chunk(ChunkMeta.t()) :: {:ok, String.t()} | {:error, :crdt_unavailable}
  defp store_chunk(%ChunkMeta{} = chunk_meta) do
    index = %{
      hash: chunk_meta.hash,
      size: chunk_meta.size,
      ref_count: 1
    }

    key = chunk_meta.encrypted_chunk_key

    case ChunkIndex.put(key, index) do
      {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
      :ok -> {:ok, key}
    end
  end
end

# ── FileIndex — distributed CRDT-backed map of file entries ───────────────────

defmodule Dust.Mesh.Manifest.FileIndex do
  @moduledoc """
  Distributed shared map for file manifest entries.

  Keys are UUID strings identifying a file. Values are maps with
  `:encrypted_file_key` and `:chunks` (ordered list of chunk IDs).
  """

  use Dust.Mesh.SharedMap

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

# ── ChunkIndex — distributed CRDT-backed map of chunk metadata ────────────────

defmodule Dust.Mesh.Manifest.ChunkIndex do
  @moduledoc """
  Distributed shared map for chunk metadata with reference counting.

  Keys are encrypted chunk keys (binary strings). Values are maps with
  `:hash`, `:size`, and `:ref_count`. Duplicate puts increment the
  reference count; deletes decrement it and only remove the entry when
  the count reaches zero.
  """

  use Dust.Mesh.SharedMap

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
