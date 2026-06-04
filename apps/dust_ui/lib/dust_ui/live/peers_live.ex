defmodule Dust.Ui.PeersLive do
  @moduledoc """
  Live dashboard of peer status and Tailscale bridge state.
  """
  use Dust.Ui, :live_view

  import Dust.Ui.PeerCard

  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      _ = Dust.Mesh.NodeRegistry.subscribe()
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, page_title: "Peers") |> assign_state()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_state(socket)}
  end

  def handle_info({:node_registry_changes, _state}, socket),
    do: {:noreply, assign_state(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-xl font-semibold">Peers</h2>
        <p class="text-sm text-zinc-500">Cluster membership and Tailscale bridge state.</p>
      </div>

      <div class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm">
        <p class="text-xs font-medium uppercase tracking-wide text-zinc-500">Tailscale</p>
        <p class="mt-2 text-sm">
          <span class="font-medium">State:</span> {@bridge.state}
        </p>
        <p :if={@bridge.self_ip} class="mt-1 text-sm">
          <span class="font-medium">IP:</span>
          <span class="font-mono">{@bridge.self_ip}</span>
        </p>
        <p :if={@bridge.auth_url} class="mt-1 text-sm">
          <a href={@bridge.auth_url} target="_blank" rel="noopener" class="text-zinc-700 underline hover:text-zinc-900">
            Open auth URL
          </a>
        </p>
        <p :if={@bridge.error} class="mt-1 text-sm text-rose-600">
          Bridge error: {@bridge.error}
        </p>
      </div>

      <div :if={@peers == []} class="rounded-md border border-dashed border-zinc-300 bg-white p-6 text-center text-sm text-zinc-500">
        No peers known yet.
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <.peer_card
          :for={p <- @peers}
          node={p.node}
          status={p.status}
          seen_at={p.seen_at}
          fitness={p.fitness}
        />
      </div>
    </div>
    """
  end

  defp assign_state(socket) do
    bridge =
      case safe(fn -> Dust.Bridge.auth_status() end, :error) do
        {:ok, info} -> Map.merge(%{state: "unknown", self_ip: nil, auth_url: nil, error: nil}, info)
        {:error, reason} -> %{state: "error", self_ip: nil, auth_url: nil, error: inspect(reason)}
        :error -> %{state: "unavailable", self_ip: nil, auth_url: nil, error: nil}
      end

    registry = safe(fn -> Dust.Mesh.NodeRegistry.list() end, %{})
    fitness_by_node = safe(fn -> Dust.Core.Fitness.list() end, []) |> Map.new()

    peers =
      registry
      |> Enum.map(fn {node, info} ->
        %{
          node: node,
          status: Map.get(info, :status, :unknown),
          seen_at: Map.get(info, :seen_at),
          fitness: Map.get(fitness_by_node, node)
        }
      end)
      |> Enum.sort_by(fn p -> {p.status != :online, to_string(p.node)} end)

    assign(socket, bridge: bridge, peers: peers)
  end

  defp safe(fun, fallback) do
    try do
      fun.()
    catch
      :exit, _ -> fallback
      kind, _ when kind in [:error, :throw] -> fallback
    end
  end
end
