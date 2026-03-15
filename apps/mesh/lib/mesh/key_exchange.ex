defmodule Mesh.KeyExchange do
  @moduledoc """
  Coordinates master-key exchange across the Dust peer mesh.

  On node startup, the mesh layer checks if a local master key exists.
  If it does, it tells the Bridge to start serving the key so new peers
  can request it. If not, it attempts to fetch the key from a seed peer.
  """

  require Logger

  alias Dust.Core.KeyStore

  # ── Configurable bridge module (allows Mox in tests) ────────────────────

  defp bridge, do: Application.get_env(:mesh, :bridge_module, Bridge)

  @doc """
  Bootstrap the master key for this node.

  Call this after the `KeyStore` and `Bridge` GenServers are running.

  1. If `KeyStore` already has a key → start serving it to peers.
  2. If not → iterate through `seed_peers` and request the key.
  """
  @spec bootstrap_key() :: :ok | {:error, term()}
  def bootstrap_key do
    if KeyStore.has_key?() do
      serve_local_key()
    else
      fetch_key_from_peers()
    end
  end

  @doc """
  Request the master key from a specific peer address.

  On success, stores the key in `KeyStore` and begins serving it.
  """
  @spec request_key_from_peer(String.t()) :: :ok | {:error, term()}
  def request_key_from_peer(peer_address) do
    Logger.info("KeyExchange: requesting master key from #{peer_address}")

    case bridge().request_key(peer_address) do
      {:ok, key} ->
        :ok = KeyStore.set_key(key)
        Logger.info("KeyExchange: master key received and stored")
        serve_local_key()

      {:error, reason} ->
        Logger.warning("KeyExchange: failed to get key from #{peer_address}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Start serving the local master key so peers can request it.
  """
  @spec serve_local_key() :: :ok | {:error, term()}
  def serve_local_key do
    case KeyStore.get_key() do
      {:ok, key} ->
        Logger.info("KeyExchange: advertising master key to peers")
        bridge().serve_key(key)

      {:error, :not_initialized} ->
        {:error, :no_key_to_serve}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp fetch_key_from_peers do
    peers = seed_peers()

    if peers == [] do
      Logger.info("KeyExchange: no seed peers configured, generating new master key")
      # KeyStore already generated one on init — just serve it
      serve_local_key()
    else
      result =
        Enum.reduce_while(peers, {:error, :no_peers_responded}, fn peer, _acc ->
          case request_key_from_peer(peer) do
            :ok -> {:halt, :ok}
            {:error, _} -> {:cont, {:error, :no_peers_responded}}
          end
        end)

      case result do
        :ok -> :ok
        {:error, _reason} ->
          Logger.warning("KeyExchange: could not reach any seed peer, using locally generated key")
          serve_local_key()
      end
    end
  end

  defp seed_peers do
    Application.get_env(:mesh, :seed_peers, [])
  end
end
