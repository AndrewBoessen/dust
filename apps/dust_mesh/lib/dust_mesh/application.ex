defmodule Dust.Mesh.Application do
  @moduledoc false

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
