defmodule Dust.Ui.CoreComponents do
  @moduledoc """
  Minimal core component library for the Dust web UI.

  Provides building blocks (`button`, `input`, `flash`) used across the
  login page and dashboards. Styling is Tailwind utility classes.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice (`:info` or `:error`).
  """
  attr :kind, :atom, values: [:info, :error], doc: "the kind of flash"
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :title, :string, default: nil
  attr :id, :string, default: nil
  slot :inner_block

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id || "flash-#{@kind}"}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 max-w-sm rounded-lg p-3 ring-1 shadow",
        @kind == :info && "bg-emerald-50 text-emerald-900 ring-emerald-200",
        @kind == :error && "bg-rose-50 text-rose-900 ring-rose-200"
      ]}
    >
      <p :if={@title} class="text-sm font-semibold leading-6">{@title}</p>
      <p class="text-sm leading-5">{msg}</p>
    </div>
    """
  end

  @doc "Renders a group of flash messages from `@flash`."
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} title="Heads up" flash={@flash} />
    <.flash kind={:error} title="Error" flash={@flash} />
    """
  end

  @doc """
  Renders a styled button. Either drives a `phx-click` event or, with
  `type="submit"`, submits the surrounding form.
  """
  attr :type, :string, default: "button"
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center rounded-md bg-zinc-900 px-4 py-2",
        "text-sm font-semibold text-white shadow-sm hover:bg-zinc-700",
        "disabled:opacity-50 disabled:cursor-not-allowed",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders a labelled form input.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :type, :string, default: "text"
  attr :errors, :list, default: []
  attr :rest, :global, include: ~w(autocomplete placeholder required)

  def input(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <label :if={@label} for={@id} class="text-sm font-medium text-zinc-700">
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id || @name}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "block w-full rounded-md border-0 px-3 py-2 text-zinc-900 shadow-sm",
          "ring-1 ring-inset ring-zinc-300 placeholder:text-zinc-400",
          "focus:ring-2 focus:ring-inset focus:ring-zinc-900",
          "sm:text-sm sm:leading-6",
          @errors != [] && "ring-rose-400 focus:ring-rose-500"
        ]}
        {@rest}
      />
      <p :for={msg <- @errors} class="text-sm text-rose-600">{msg}</p>
    </div>
    """
  end

  @doc """
  Hides an element with a Phoenix LiveView JS transition.
  """
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
  end

  @doc """
  A simple modal overlay. Dismiss-on-backdrop-click sends `on_close` to
  the parent LiveView.
  """
  attr :title, :string, default: nil
  attr :on_close, :string, default: "close_modal"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div id="modal-overlay" class="fixed inset-0 z-40 flex items-center justify-center">
      <div class="absolute inset-0 bg-zinc-900/40" phx-click={@on_close}></div>
      <div class="relative z-10 w-full max-w-md rounded-lg bg-white p-6 shadow-xl">
        <div class="mb-4 flex items-center justify-between">
          <h3 :if={@title} class="text-base font-semibold text-zinc-900">{@title}</h3>
          <button
            type="button"
            phx-click={@on_close}
            class="text-zinc-400 hover:text-zinc-700"
            aria-label="Close"
          >
            ×
          </button>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
