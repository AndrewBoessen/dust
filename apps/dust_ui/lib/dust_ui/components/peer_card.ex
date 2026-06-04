defmodule Dust.Ui.PeerCard do
  @moduledoc false
  use Phoenix.Component

  alias Dust.Ui.Format

  attr :node, :atom, required: true
  attr :status, :atom, required: true
  attr :seen_at, :any, default: nil
  attr :fitness, :map, default: nil

  def peer_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm">
      <div class="flex items-start justify-between">
        <div>
          <p class="font-mono text-sm font-medium text-zinc-900">{to_string(@node)}</p>
          <p class="mt-1 text-xs text-zinc-500">
            Last seen {Format.relative_time(@seen_at)}
          </p>
        </div>
        <span class={[
          "rounded-full px-2 py-0.5 text-xs font-medium",
          @status == :online && "bg-emerald-100 text-emerald-700",
          @status == :offline && "bg-zinc-100 text-zinc-500",
          @status == :unknown && "bg-amber-100 text-amber-700"
        ]}>
          {to_string(@status)}
        </span>
      </div>

      <dl :if={@fitness} class="mt-4 grid grid-cols-3 gap-3 text-sm">
        <div>
          <dt class="text-xs uppercase tracking-wide text-zinc-500">Success</dt>
          <dd class="font-medium text-zinc-900">{Format.percent(@fitness.success_rate, 0)}</dd>
        </div>
        <div>
          <dt class="text-xs uppercase tracking-wide text-zinc-500">Latency</dt>
          <dd class="font-medium text-zinc-900">{:erlang.float_to_binary(@fitness.latency_ms / 1.0, decimals: 0)} ms</dd>
        </div>
        <div>
          <dt class="text-xs uppercase tracking-wide text-zinc-500">Bandwidth</dt>
          <dd class="font-medium text-zinc-900">{:erlang.float_to_binary(@fitness.bandwidth / 1.0, decimals: 1)} Mb/s</dd>
        </div>
      </dl>
    </div>
    """
  end
end
