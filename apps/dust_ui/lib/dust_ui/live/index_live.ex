defmodule Dust.Ui.IndexLive do
  @moduledoc """
  Top-level dashboard. Three stat cards (files / peers / storage) plus a
  system-readiness banner.
  """
  use Dust.Ui, :live_view

  import Dust.Ui.StatCard

  alias Dust.Ui.Format

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      _ = Registry.register(Dust.Daemon.Registry, :system_ready, [])
      _ = Dust.Mesh.NodeRegistry.subscribe()
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, page_title: "Dashboard") |> assign_metrics()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_metrics(socket)}
  end

  def handle_info({:system_ready, _node}, socket), do: {:noreply, assign_metrics(socket)}

  def handle_info({:node_registry_changes, _state}, socket),
    do: {:noreply, assign_metrics(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div :if={not @system_ready?} class="rounded-md bg-amber-50 p-3 text-sm text-amber-900 ring-1 ring-amber-200">
        Daemon is still bootstrapping. Some statistics may be unavailable.
      </div>

      <h2 class="text-xl font-semibold">Overview</h2>

      <div class="grid gap-4 sm:grid-cols-3">
        <.stat_card
          title="Files"
          value={Integer.to_string(@files_count)}
          subtitle={"#{@dirs_count} directories"}
          href={~p"/files"}
        />
        <.stat_card
          title="Peers online"
          value={Integer.to_string(@online_peer_count)}
          subtitle={"#{@total_peer_count} known"}
          href={~p"/peers"}
        />
        <.stat_card
          title="Storage"
          value={Format.bytes(@used_bytes)}
          subtitle={"of #{Format.bytes(@quota_bytes)} quota"}
          href={~p"/storage"}
        />
      </div>
    </div>
    """
  end

  defp assign_metrics(socket) do
    system_ready? = Dust.Daemon.Readiness.ready?()
    registry = safe(fn -> Dust.Mesh.NodeRegistry.list() end, %{})
    online = safe(fn -> Dust.Mesh.NodeRegistry.online_nodes() end, [])
    files_count = safe(fn -> Dust.Mesh.FileSystem.all_files() |> map_size() end, 0)
    dirs_count = safe(fn -> Dust.Mesh.FileSystem.all_dirs() |> map_size() end, 0)
    quota_bytes = safe(fn -> Dust.Daemon.DiskManager.get_quota() end, 0)
    used_bytes = safe(fn -> Dust.Daemon.DiskManager.usage_bytes() end, 0)

    assign(socket,
      system_ready?: system_ready?,
      files_count: files_count,
      dirs_count: dirs_count,
      online_peer_count: length(online),
      total_peer_count: map_size(registry),
      used_bytes: used_bytes,
      quota_bytes: quota_bytes
    )
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
