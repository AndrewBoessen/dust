defmodule Dust.Bridge.Discovery do
  @moduledoc """
  Periodically queries the tsnet sidecar for peer Tailscale IPs and attempts
  to form an Erlang cluster with them.
  """
  use GenServer
  require Logger

  @poll_interval 15_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll_peers, state) do
    case Dust.Bridge.get_peers() do
      {:ok, peers} ->
        connect_to_peers(peers)

      {:error, reason} ->
        Logger.warning("Discovery: Failed to get peers from sidecar: #{inspect(reason)}")
    end

    schedule_poll()
    {:noreply, state}
  end

  defp connect_to_peers(peers) do
    # Filter out our own node
    current_ip =
      Node.self()
      |> to_string()
      |> String.split("@")
      |> List.last()

    peers
    |> Enum.reject(&(&1 == current_ip))
    |> Enum.each(fn peer_ip ->
      peer_node = String.to_atom("dust@" <> peer_ip)

      if peer_node not in Node.list() do
        Logger.debug("Discovery: Attempting to connect to #{peer_node}")
        # Node.connect will invoke our custom EPMD module and proxy target
        Node.connect(peer_node)
      end
    end)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll_peers, @poll_interval)
  end
end
