defmodule Dust.Bridge.Behaviour do
  @moduledoc """
  Behaviour defining the Bridge API surface.

  Implemented by `Dust.Bridge` (the real GenServer-based port driver) and
  by test mocks. Consumers such as `Dust.Core.KeyStore` resolve the
  concrete module via `Application.get_env(:dust_bridge, :bridge_module)`,
  allowing the implementation to be swapped at test time.
  """

  @doc "Joins an existing mesh by requesting secrets from a peer node."
  @callback join(peer_address :: String.t(), token :: String.t()) ::
              {:ok, master_key_b64 :: String.t(), otp_cookie :: String.t()} | {:error, term()}

  @doc "Instructs the sidecar to serve the master key and OTP cookie to joining peers."
  @callback serve_secrets(master_key_b64 :: String.t(), otp_cookie :: String.t()) ::
              :ok | {:error, term()}

  @doc "Creates a one-time invite token and registers it with the sidecar."
  @callback create_invite() :: {:ok, token :: String.t()} | {:error, term()}

  @doc "Returns the Tailscale IPs of all peers visible to the sidecar."
  @callback get_peers() :: {:ok, [String.t()]} | {:error, term()}

  @doc "Opens a local TCP proxy to `target_ip:target_port` over Tailscale."
  @callback proxy(target_ip :: String.t(), target_port :: integer()) ::
              {:ok, local_port :: integer()} | {:error, term()}

  @doc "Exposes a local `port` on the node's Tailscale IP via the sidecar."
  @callback expose(port :: integer()) :: :ok | {:error, term()}

  @doc "Returns the current Tailscale auth status: state, self IP, and login URL (if pending)."
  @callback auth_status() ::
              {:ok, %{state: String.t(), self_ip: String.t(), auth_url: String.t()}}
              | {:error, term()}
end
