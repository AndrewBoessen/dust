defmodule Dust.Bridge.EPMD do
  @moduledoc """
  Custom EPMD module that routes Erlang distribution over Tailscale.

  Standard EPMD resolves node names to `{host, port}` pairs using the
  system-wide `epmd` daemon. This module replaces that mechanism: instead
  of querying `epmd`, it asks the Go `tsnet_sidecar` to open a local TCP
  proxy that tunnels distribution traffic through the Tailscale network.

  ## How it works

  When `net_kernel` needs to connect to a remote node it calls
  `address_please/3` (or `port_please/3` on older OTP releases). This
  module responds by:

  1. Asking `Dust.Bridge.proxy/2` to dial the peer's distribution port
     (9000) over Tailscale.
  2. Returning the resulting **local** proxy port so that `net_kernel`
     connects to `127.0.0.1:<proxy_port>` transparently.

  ## Configuration

  Set the VM flag `-epmd_module Dust.Bridge.EPMD` (or via `vm.args`) to
  activate this module.

  The fixed distribution listening port (9000) must match the port
  exposed by `Dust.Bridge.Setup`.
  """

  @dist_port 9000

  # ── Callbacks used by :net_kernel ────────────────────────────────────────

  @doc """
  Resolves a remote node's distribution address by opening a local proxy
  through Tailscale.

  Called by `:net_kernel` on OTP 25+. Returns `{:ok, address, port, version}`
  where `address` is `127.0.0.1` (the local proxy endpoint) and `port` is the
  dynamically assigned proxy port.
  """
  @spec address_please(charlist(), charlist(), :inet | :inet6) ::
          {:ok, :inet.ip_address(), non_neg_integer(), 1..5} | {:error, :address}
  def address_please(_name, host, _address_family) do
    peer_ip = to_string(host)

    case Dust.Bridge.proxy(peer_ip, @dist_port) do
      {:ok, local_port} ->
        {:ok, {127, 0, 0, 1}, local_port, 5}

      _error ->
        {:error, :address}
    end
  end

  @doc """
  Legacy callback for resolving a remote node's distribution port.

  Superseded by `address_please/3` on modern OTP but retained for
  backwards compatibility. Returns `{:port, port, version}`.
  """
  @spec port_please(charlist(), charlist(), timeout()) ::
          {:port, non_neg_integer(), 1..5}
  def port_please(_name, host, _timeout \\ 5000) do
    peer_ip = to_string(host)

    case Dust.Bridge.proxy(peer_ip, @dist_port) do
      {:ok, local_port} ->
        {:port, local_port, 5}

      _error ->
        {:port, 0, 5}
    end
  end

  @doc """
  Returns the fixed port this node listens on for incoming distribution
  connections.
  """
  @spec listen_port_please(charlist(), charlist()) :: {:ok, non_neg_integer()}
  def listen_port_please(_name, _host) do
    {:ok, @dist_port}
  end

  # ── Stub implementations required by the :erl_epmd interface ────────────

  @doc false
  @spec start_link() :: :ignore
  def start_link, do: :ignore

  @doc false
  @spec register_node(charlist(), non_neg_integer()) :: {:ok, pos_integer()}
  def register_node(_name, _port), do: {:ok, 1}

  @doc false
  @spec register_node(charlist(), non_neg_integer(), :inet | :inet6) :: {:ok, pos_integer()}
  def register_node(_name, _port, _family), do: {:ok, 1}

  @doc false
  @spec names(charlist()) :: {:error, :address}
  def names(_host), do: {:error, :address}
end
