defmodule Dust.Mesh.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: Dust.Mesh.Registry},
      Dust.Mesh.NodeRegistry,
      Dust.Mesh.FileSystem.DirMap,
      Dust.Mesh.FileSystem.FileMap
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Mesh.Supervisor)
  end
end
