defmodule Dust.Bridge.EPMD do
  @moduledoc """
  Custom EPMD module to route Erlang distribution over the Tailscale tsnet proxy.
  """

  # Called by net_kernel to find the port a remote node is listening on
  def port_please(_name, host, _timeout \\ 5000) do
    peer_ip = to_string(host)

    case Dust.Bridge.proxy(peer_ip, 9000) do
      {:ok, local_port} ->
        # Return {Port, Version} where Port is our dynamic proxy port
        {:port, local_port, 5}

      _error ->
        {:port, 0, 5}
    end
  end

  # When address_please is defined, the :net_kernel calls it instead of port_please
  def address_please(_name, host, _address_family) do
    peer_ip = to_string(host)

    case Dust.Bridge.proxy(peer_ip, 9000) do
      {:ok, local_port} ->
        # Return local IPv4 address (127.0.0.1) and proxy port
        {:ok, {127, 0, 0, 1}, local_port, 5}

      _error ->
        {:error, :address}
    end
  end

  def listen_port_please(_name, _host) do
    # Return the fixed listening port 9000 for standard Dist over tsnet
    {:ok, 9000}
  end

  # Dummy implementations required by the :erl_epmd interface
  def start_link, do: :ignore
  def register_node(_name, _port), do: {:ok, 1}
  def register_node(_name, _port, _family), do: {:ok, 1}
  def names(_host), do: {:error, :address}
end
