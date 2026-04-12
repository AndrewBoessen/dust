defmodule Dust.Storage do
  @moduledoc """
  Local shard storage layer for the Dust network.

  Stores and retrieves encrypted, erasure-coded shard binaries on the
  local node.  Keys are composite strings `"{chunk_hash}:{shard_index}"`
  matching the format used by `Dust.Mesh.Manifest.ShardMap`.

  Backed by RocksDB with BlobDB enabled for efficient ~1 MB value storage.

  ## Examples

      iex> Dust.Storage.put_shard("abc123", 0, <<1, 2, 3>>)
      :ok

      iex> Dust.Storage.get_shard("abc123", 0)
      {:ok, <<1, 2, 3>>}

      iex> Dust.Storage.has_shard?("abc123", 0)
      true

      iex> Dust.Storage.delete_shard("abc123", 0)
      :ok

      iex> Dust.Storage.get_shard("abc123", 0)
      {:error, :not_found}
  """

  alias Dust.Storage.RocksBackend

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Store an encrypted shard binary under its composite key.
  """
  @spec put_shard(String.t(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  def put_shard(chunk_hash, shard_index, encrypted_binary)
      when is_binary(chunk_hash) and is_integer(shard_index) and shard_index >= 0 and
             is_binary(encrypted_binary) do
    hash = :crypto.hash(:sha256, encrypted_binary)
    payload_to_store = encrypted_binary <> hash

    RocksBackend.put(key(chunk_hash, shard_index), payload_to_store)
  end

  @doc """
  Retrieve an encrypted shard binary by its composite key.

  Returns `{:ok, binary}` on success, or `{:error, :not_found}` if the
  shard is not stored locally.
  """
  @spec get_shard(String.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :not_found | :integrity_check_failed | :invalid_format}
  def get_shard(chunk_hash, shard_index)
      when is_binary(chunk_hash) and is_integer(shard_index) and shard_index >= 0 do
    case RocksBackend.get(key(chunk_hash, shard_index)) do
      {:ok, stored_value} when byte_size(stored_value) >= 32 ->
        payload_size = byte_size(stored_value) - 32
        <<payload::binary-size(payload_size), stored_hash::binary-32>> = stored_value

        if :crypto.hash(:sha256, payload) == stored_hash do
          {:ok, payload}
        else
          {:error, :integrity_check_failed}
        end

      {:ok, _stored_value} ->
        {:error, :invalid_format}

      error ->
        error
    end
  end

  @doc """
  Verifies the local integrity of a shard without returning its binary payload.

  Returns `:ok` if the shard exists and its checksum matches, `{:error, :not_found}` if missing,
  or `{:error, :integrity_check_failed}` if corrupted.
  """
  @spec verify_shard(String.t(), non_neg_integer()) ::
          :ok | {:error, :not_found | :integrity_check_failed | :invalid_format}
  def verify_shard(chunk_hash, shard_index)
      when is_binary(chunk_hash) and is_integer(shard_index) and shard_index >= 0 do
    case RocksBackend.get(key(chunk_hash, shard_index)) do
      {:ok, stored_value} when byte_size(stored_value) >= 32 ->
        payload_size = byte_size(stored_value) - 32
        <<payload::binary-size(payload_size), stored_hash::binary-32>> = stored_value

        if :crypto.hash(:sha256, payload) == stored_hash do
          :ok
        else
          {:error, :integrity_check_failed}
        end

      {:ok, _stored_value} ->
        {:error, :invalid_format}

      error ->
        error
    end
  end

  @doc """
  Delete an encrypted shard by its composite key.

  Returns `:ok` regardless of whether the key existed.
  """
  @spec delete_shard(String.t(), non_neg_integer()) :: :ok
  def delete_shard(chunk_hash, shard_index)
      when is_binary(chunk_hash) and is_integer(shard_index) and shard_index >= 0 do
    RocksBackend.delete(key(chunk_hash, shard_index))
  end

  @doc """
  Delete all shards for a chunk (indices `0..total_shards-1`).

  Typically called when a chunk's reference count reaches zero in the
  manifest and all shard data should be garbage-collected locally.
  """
  @spec delete_chunk_shards(String.t(), non_neg_integer()) :: :ok
  def delete_chunk_shards(chunk_hash, total_shards)
      when is_binary(chunk_hash) and is_integer(total_shards) and total_shards >= 0 do
    for i <- 0..(total_shards - 1)//1 do
      RocksBackend.delete(key(chunk_hash, i))
    end

    :ok
  end

  @doc """
  Returns the approximate size in bytes of a locally stored shard,
  or `nil` if the shard does not exist.

  Reads the raw value from RocksDB and strips the 32-byte checksum
  trailer — no integrity verification is performed, making this a
  fast path for disk-quota estimation in the repair scheduler.
  """
  @spec shard_size(String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def shard_size(chunk_hash, shard_index)
      when is_binary(chunk_hash) and is_integer(shard_index) and shard_index >= 0 do
    case RocksBackend.get(key(chunk_hash, shard_index)) do
      {:ok, stored_value} when byte_size(stored_value) >= 32 ->
        byte_size(stored_value) - 32

      {:ok, stored_value} ->
        byte_size(stored_value)

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  Check if a shard exists locally without reading the full binary.
  """
  @spec has_shard?(String.t(), non_neg_integer()) :: boolean()
  def has_shard?(chunk_hash, shard_index)
      when is_binary(chunk_hash) and is_integer(shard_index) and shard_index >= 0 do
    RocksBackend.has_key?(key(chunk_hash, shard_index))
  end

  @doc """
  Returns all locally-stored shard keys as `{chunk_hash, shard_index}` tuples.

  Iterates over RocksDB keys without reading values, making it safe for
  large stores. Used by the garbage collector to reconcile local storage
  against the distributed manifest.
  """
  @spec list_local_shard_keys() :: [{String.t(), non_neg_integer()}]
  def list_local_shard_keys do
    RocksBackend.fold_keys(
      fn key, acc ->
        case String.split(key, ":", parts: 2) do
          [chunk_hash, idx_str] -> [{chunk_hash, String.to_integer(idx_str)} | acc]
          _ -> acc
        end
      end,
      []
    )
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec key(String.t(), non_neg_integer()) :: String.t()
  defp key(chunk_hash, shard_index), do: "#{chunk_hash}:#{shard_index}"
end
