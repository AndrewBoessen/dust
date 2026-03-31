defmodule Dust.Mesh do
  @moduledoc """
  Distributed mesh network layer for the Dust network.

  Provides cluster-wide data structures backed by DeltaCrdt
  (add-wins last-writer-wins maps) that sync automatically across all
  connected Erlang nodes.

  ## Submodules

    * `Dust.Mesh.NodeRegistry`   — tracks online/offline status of cluster peers
    * `Dust.Mesh.FileSystem`     — distributed virtual file system (directories + files)
    * `Dust.Mesh.Manifest`       — content-addressable index of encrypted chunks and shard placements
    * `Dust.Mesh.SharedMap`      — reusable `use`-macro providing CRDT-backed map boilerplate
  """
end
