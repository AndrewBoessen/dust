defmodule Dust.Utilities.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Dust.Utilities.Config.load!()

    children = []
    opts = [strategy: :one_for_one, name: Dust.Utilities.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
