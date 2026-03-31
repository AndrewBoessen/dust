defmodule Dust.Storage do
  @moduledoc """
  Local chunk storage layer for the Dust network.

  Responsible for persisting and retrieving encrypted, erasure-coded shards
  on the local node's filesystem. This application is consumed by the mesh
  layer to fulfill storage and retrieval requests from peer nodes.
  """
end
