defmodule Dust.Storage.RocksBackend do
  @moduledoc """
  GenServer that owns and manages the RocksDB database handle.

  Stores encrypted erasure-coded shard binaries keyed by composite
  strings of the form `"{chunk_hash}:{shard_index}"` — the same
  key format used by `Dust.Mesh.Manifest.ShardMap`.

  ## RocksDB Configuration

  The database is tuned for ~1 MB encrypted blob values:

    * **BlobDB** is enabled so large values are stored in separate blob
      files rather than inline in the LSM tree.  This avoids write
      amplification during compaction.
    * **Compression is disabled** because the values are AES-256-GCM
      ciphertext, which is incompressible.
    * **`min_blob_size`** is set to 4 096 bytes — values smaller than
      this threshold are stored inline (unlikely in practice).

  ## Crash Isolation

  Because `:rocksdb` is a C++ NIF, a segfault will take down the BEAM.
  This module is intentionally placed inside its own supervised
  application (`dust_storage`) so that the blast radius is as contained
  as OTP allows.
  """

  use GenServer

  require Logger

  @name __MODULE__

  # ── Public helpers (called by Dust.Storage) ────────────────────────────

  @doc false
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, value) when is_binary(key) and is_binary(value) do
    GenServer.call(@name, {:put, key, value})
  end

  @doc false
  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    GenServer.call(@name, {:get, key})
  end

  @doc false
  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    GenServer.call(@name, {:delete, key})
  end

  @doc false
  @spec has_key?(String.t()) :: boolean()
  def has_key?(key) when is_binary(key) do
    GenServer.call(@name, {:has_key, key})
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    db_path = db_path()

    File.mkdir_p!(db_path)

    db_opts = [
      create_if_missing: true,
      # ── BlobDB settings ───────────────────────────────────────────────
      enable_blob_files: true,
      min_blob_size: 4_096,
      enable_blob_garbage_collection: true,
      # ── Compression ───────────────────────────────────────────────────
      # Values are AES-256-GCM ciphertext — incompressible.
      compression: :none,
      blob_compression_type: :none
    ]

    case :rocksdb.open(to_charlist(db_path), db_opts) do
      {:ok, db_handle} ->
        Logger.info("Dust.Storage.RocksBackend: opened database at #{db_path}")
        {:ok, %{db: db_handle}}

      {:error, reason} ->
        Logger.error("Dust.Storage.RocksBackend: failed to open database: #{inspect(reason)}")
        {:stop, {:rocksdb_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, key, value}, _from, %{db: db} = state) do
    result =
      case :rocksdb.put(db, key, value, []) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:get, key}, _from, %{db: db} = state) do
    result =
      case :rocksdb.get(db, key, []) do
        {:ok, value} -> {:ok, value}
        not_found when not_found in [:not_found, {:error, :not_found}] -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, key}, _from, %{db: db} = state) do
    :rocksdb.delete(db, key, [])
    {:reply, :ok, state}
  end

  def handle_call({:has_key, key}, _from, %{db: db} = state) do
    result =
      case :rocksdb.get(db, key, []) do
        {:ok, _value} -> true
        _ -> false
      end

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{db: db}) do
    Logger.info("Dust.Storage.RocksBackend: closing database")
    :rocksdb.close(db)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private ────────────────────────────────────────────────────────────

  defp db_path do
    Dust.Utilities.File.storage_db_dir()
  end
end
