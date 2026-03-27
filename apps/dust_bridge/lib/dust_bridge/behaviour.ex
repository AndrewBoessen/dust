defmodule Dust.Bridge.Behaviour do
  @moduledoc """
  Behaviour defining the Bridge API surface.

  Used by `Mesh.KeyExchange` so the bridge implementation can be
  swapped for a mock in tests.
  """

  @callback join(String.t(), String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  @callback serve_secrets(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_invite() :: {:ok, String.t()} | {:error, term()}
  @callback get_peers() :: {:ok, [String.t()]} | {:error, term()}
  @callback proxy(String.t(), integer()) :: {:ok, integer()} | {:error, term()}
  @callback expose(integer()) :: :ok | {:error, term()}
end
