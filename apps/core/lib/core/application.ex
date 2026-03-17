defmodule Dust.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Dust.Core.KeyStore, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Core.Supervisor)
  end
end
