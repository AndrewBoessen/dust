defmodule Dust.Bridge.Behaviour do
  @moduledoc """
  Behaviour defining the Bridge API surface.

  Used by `Mesh.KeyExchange` so the bridge implementation can be
  swapped for a mock in tests.
  """

  @callback request_key(String.t()) :: {:ok, binary()} | {:error, term()}
  @callback serve_key(binary()) :: :ok | {:error, term()}
  @callback get_peers() :: {:ok, [String.t()]} | {:error, term()}
  @callback proxy(String.t(), integer()) :: {:ok, integer()} | {:error, term()}
  @callback expose(integer()) :: :ok | {:error, term()}
end
