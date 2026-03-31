defmodule Dust.Bridge.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Dust.Bridge.Secrets,
      Dust.Bridge,
      Dust.Bridge.Setup,
      Dust.Bridge.Discovery
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Bridge.Supervisor)
  end
end
