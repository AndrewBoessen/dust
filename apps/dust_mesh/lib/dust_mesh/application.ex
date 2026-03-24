defmodule Dust.Mesh.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:dust_mesh, :data_dir, Path.expand("~/.dust/dust_mesh_db"))

    children = [
      {Registry, keys: :duplicate, name: Dust.Mesh.Registry},
      {CubDB, data_dir: data_dir, name: Dust.Mesh.Database},
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
