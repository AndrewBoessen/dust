defmodule Dust.Ui.StatCard do
  @moduledoc false
  use Phoenix.Component

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :subtitle, :string, default: nil
  attr :href, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm">
      <p class="text-xs font-medium uppercase tracking-wide text-zinc-500">{@title}</p>
      <p class="mt-2 text-2xl font-semibold text-zinc-900">{@value}</p>
      <p :if={@subtitle} class="mt-1 text-sm text-zinc-500">{@subtitle}</p>
      <.link
        :if={@href}
        navigate={@href}
        class="mt-3 inline-block text-sm font-medium text-zinc-700 hover:text-zinc-900"
      >
        View &rarr;
      </.link>
    </div>
    """
  end
end
