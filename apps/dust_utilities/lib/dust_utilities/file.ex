defmodule Dust.Utilities.File do
  @moduledoc """
  Centralized file path management for persistent data structures.

  All persistent paths in the Dust umbrella resolve through this module.
  The root directory defaults to `~/.dust` but is configurable via the
  `:dust_utilities` application environment:

      config :dust_utilities, persist_dir: "/custom/path"

  ## Directory layout

      <persist_dir>/
      ├── master.key              # encrypted master key (Dust.Core.KeyStore)
      ├── fitness_models/         # CubDB database for NodeEMA models
      ├── mesh_db/                # CubDB database for mesh CRDTs
      ├── storage_db/             # RocksDB database for encrypted shard blobs
      └── ts_state/
          └── tsnet-state-<node>/ # per-node Tailscale tsnet state
              └── secrets.json    # persisted OTP cookie
  """

  @master_key_file "master.key"
  @fitness_model_dir "fitness_models"
  @mesh_db_dir "mesh_db"
  @storage_db_dir "storage_db"
  @ts_state_root "ts_state"
  @node_ts_state_prefix "tsnet-state"
  @secrets_file "secrets.json"
  @default_node_name "unknown"
  @disk_quato_file "disk_quota.json"

  @doc """
  Returns the base persistence directory.

  Reads the `:persist_dir` key from the `:dust_utilities` application
  environment. Defaults to `~/.dust`.

  ## Examples

      iex> Dust.Utilities.File.persist_dir()
      "/home/user/.dust"

  """
  @spec persist_dir() :: Path.t()
  def persist_dir do
    Application.get_env(
      :dust_utilities,
      :persist_dir,
      Path.join([System.user_home!(), ".dust"])
    )
  end

  @doc """
  Absolute path to the `master.key` file.

  The file contains the network-wide master key encrypted at rest with
  a device-bound key derived from the user's password.
  """
  @spec master_key_file() :: Path.t()
  def master_key_file do
    Path.join(persist_dir(), @master_key_file)
  end

  @doc """
  Absolute path to the `fitness_models/` directory.

  Stores the CubDB database backing `Dust.Core.Fitness.ModelStore`.
  """
  @spec fitness_models_dir() :: Path.t()
  def fitness_models_dir do
    Path.join(persist_dir(), @fitness_model_dir)
  end

  @doc """
  Absolute path to the `mesh_db/` directory.

  Stores the CubDB database backing the mesh layer's CRDT persistence
  (see `Dust.Mesh.SharedMap.Storage`).
  """
  @spec mesh_db_dir() :: Path.t()
  def mesh_db_dir do
    Path.join(persist_dir(), @mesh_db_dir)
  end

  @doc """
  Absolute path to the `storage_db/` directory.

  Stores the RocksDB database backing `Dust.Storage` for encrypted,
  erasure-coded shard blobs.
  """
  @spec storage_db_dir() :: Path.t()
  def storage_db_dir do
    Path.join(persist_dir(), @storage_db_dir)
  end

  @doc """
  Absolute path to the tsnet state directory for the given node prefix.

  The Go `tsnet_sidecar` stores its Tailscale state here. Each node in
  a local dev cluster gets its own subdirectory keyed by `prefix`.

  Defaults to a prefix derived from `Node.self()` (the part before `@`).
  """
  @spec ts_state_dir(String.t()) :: Path.t()
  def ts_state_dir(prefix \\ node_prefix()) do
    Path.join([persist_dir(), @ts_state_root, "#{@node_ts_state_prefix}-#{prefix}"])
  end

  @doc """
  Absolute path to the `secrets.json` file for the given node prefix.

  Contains the persisted OTP cookie stored by `Dust.Bridge.Secrets`.
  Defaults to a prefix derived from `Node.self()`.
  """
  @spec secrets_file(String.t()) :: Path.t()
  def secrets_file(prefix \\ node_prefix()) do
    Path.join(ts_state_dir(prefix), @secrets_file)
  end

  @doc """
  Absolute path to the `disk_quota.json` file.

  Store the upper bound on the number of bytes that
  can be stored on the node's database.
  """
  @spec disk_quota_file() :: Path.t()
  def disk_quota_file do
    Path.join(persist_dir(), @disk_quato_file)
  end

  # Derives a node-unique prefix from `Node.self()` for path isolation
  # in local dev clusters (e.g. "dust1" from :"dust1@127.0.0.1").
  @spec node_prefix() :: String.t()
  defp node_prefix do
    Node.self()
    |> to_string()
    |> String.split("@")
    |> List.first() || @default_node_name
  end
end
