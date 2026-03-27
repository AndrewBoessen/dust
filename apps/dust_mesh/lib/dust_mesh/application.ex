defmodule Dust.Mesh.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:dust_utilities, :persist_dir)
    mesh_db_path = Path.join(data_dir, "mesh_db")

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
