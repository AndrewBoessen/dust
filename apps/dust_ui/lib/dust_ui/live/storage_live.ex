defmodule Dust.Ui.StorageLive do
  @moduledoc """
  Storage health dashboard. Disk usage vs quota, GC and Repair scheduler
  stats, and a replication-health count.
  """
  use Dust.Ui, :live_view

  import Dust.Ui.StatCard

  alias Dust.Ui.Format

  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, page_title: "Storage") |> assign_state()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-xl font-semibold">Storage</h2>
        <p class="text-sm text-zinc-500">Local shard usage and background-sweep health.</p>
      </div>

      <div class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm">
        <div class="flex items-baseline justify-between">
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-zinc-500">Local usage</p>
            <p class="mt-1 text-2xl font-semibold">{Format.bytes(@used_bytes)}</p>
          </div>
          <p class="text-sm text-zinc-500">of {Format.bytes(@quota_bytes)}</p>
        </div>
        <div class="mt-3 h-2 w-full overflow-hidden rounded-full bg-zinc-100">
          <div class="h-full bg-zinc-900 transition-all" style={"width: #{quota_percent(@used_bytes, @quota_bytes)}%"}></div>
        </div>
        <p class="mt-2 text-xs text-zinc-500">
          {@shard_count} shards · replication factor {@replication_factor}
        </p>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <.stat_card
          title="Garbage collector"
          value={Integer.to_string(@gc.last_orphans_removed + @gc.last_replicas_removed)}
          subtitle={"Last sweep #{Format.relative_time(@gc.last_sweep_at)} · #{@gc.last_orphans_removed} orphans, #{@gc.last_replicas_removed} replicas"}
        />
        <.stat_card
          title="Repair scheduler"
          value={Integer.to_string(@repair.shards_cloned + @repair.shards_reconstructed)}
          subtitle={"Last sweep #{Format.relative_time(@repair.last_sweep_at)} · #{@repair.shards_cloned} cloned, #{@repair.shards_reconstructed} reconstructed"}
        />
        <.stat_card
          title="Integrity issues (last sweep)"
          value={Integer.to_string(@repair.integrity_removed)}
          subtitle={"Stale manifest entries: #{@repair.stale_entries_cleaned}"}
        />
        <.stat_card
          title="Under-replicated chunks"
          value={Integer.to_string(@under_replicated)}
          subtitle="Online holders below replication factor"
        />
      </div>
    </div>
    """
  end

  defp assign_state(socket) do
    quota_bytes = safe(fn -> Dust.Daemon.DiskManager.get_quota() end, 0)
    used_bytes = safe(fn -> Dust.Daemon.DiskManager.usage_bytes() end, 0)
    replication_factor = safe(fn -> Dust.Utilities.Config.replication_factor() end, 1)
    online = safe(fn -> Dust.Mesh.NodeRegistry.online_nodes() end, []) |> MapSet.new()
    gc = safe(fn -> Dust.Daemon.GarbageCollector.stats() end, default_gc())
    repair = safe(fn -> Dust.Daemon.RepairScheduler.stats() end, default_repair())

    {shard_count, under_replicated} =
      safe(
        fn -> shard_stats(Dust.Mesh.Manifest.ShardMap.all_grouped(), online, replication_factor) end,
        {0, 0}
      )

    assign(socket,
      quota_bytes: quota_bytes,
      used_bytes: used_bytes,
      replication_factor: replication_factor,
      shard_count: shard_count,
      under_replicated: under_replicated,
      gc: Map.merge(default_gc(), gc),
      repair: Map.merge(default_repair(), repair)
    )
  end

  defp shard_stats(grouped, online, replication_factor) when is_map(grouped) do
    Enum.reduce(grouped, {0, 0}, fn {_chunk_hash, shards}, {count, under} ->
      online_holders =
        shards
        |> Enum.flat_map(fn {_idx, %{nodes: nodes}} -> MapSet.to_list(nodes) end)
        |> MapSet.new()
        |> MapSet.intersection(online)
        |> MapSet.size()

      delta_under = if online_holders < replication_factor, do: 1, else: 0
      {count + 1, under + delta_under}
    end)
  end

  defp shard_stats(_, _, _), do: {0, 0}

  defp quota_percent(_used, 0), do: 0

  defp quota_percent(used, quota) when is_integer(quota) and quota > 0,
    do: trunc(used * 100 / quota) |> min(100) |> max(0)

  defp quota_percent(_, _), do: 0

  defp default_gc, do: %{last_sweep_at: nil, last_orphans_removed: 0, last_replicas_removed: 0}

  defp default_repair,
    do: %{
      last_sweep_at: nil,
      integrity_removed: 0,
      shards_cloned: 0,
      shards_reconstructed: 0,
      stale_entries_cleaned: 0
    }

  defp safe(fun, fallback) do
    try do
      fun.()
    catch
      :exit, _ -> fallback
      kind, _ when kind in [:error, :throw] -> fallback
    end
  end
end
