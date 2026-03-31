defmodule Dust.Mesh.Application do
  @moduledoc """
  OTP Application for the Dust Mesh subsystem.

  Starts the following children:

  1. `Dust.Mesh.Registry` — Elixir `Registry` used as a local pub/sub bus
     for node-status change notifications.
  2. `Dust.Mesh.Database` (`CubDB`) — embedded database persisting CRDT state.
  3. `Dust.Mesh.NodeRegistry` — tracks online/offline status of cluster peers.
  4. `Dust.Mesh.FileSystem.DirMap` — CRDT-backed distributed directory tree.
  5. `Dust.Mesh.FileSystem.FileMap` — CRDT-backed distributed file metadata.
  6. `Dust.Mesh.Manifest.FileIndex` — maps file UUIDs to encrypted keys and chunk lists.
  7. `Dust.Mesh.Manifest.ChunkIndex` — ref-counted chunk metadata index.
  8. `Dust.Mesh.Manifest.ShardMap` — tracks erasure-coded shard placements across nodes.
  """

  use Application

  @impl true
  def start(_type, _args) do
    mesh_db_path = Dust.Utilities.File.mesh_db_dir()

    children = [
      {Registry, keys: :duplicate, name: Dust.Mesh.Registry},
      {CubDB, data_dir: mesh_db_path, name: Dust.Mesh.Database},
      Dust.Mesh.NodeRegistry,
      Dust.Mesh.FileSystem.DirMap,
      Dust.Mesh.FileSystem.FileMap,
      Dust.Mesh.Manifest.FileIndex,
      Dust.Mesh.Manifest.ChunkIndex,
      Dust.Mesh.Manifest.ShardMap
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Mesh.Supervisor)
  end
end
