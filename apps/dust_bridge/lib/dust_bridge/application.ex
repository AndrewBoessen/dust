defmodule Dust.Bridge.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure OTP app is isolated
    if Node.alive?() do
      Node.set_cookie(Node.self(), :dust_mesh_cookie)
    end

    children = [
      Dust.Bridge,
      Dust.Bridge.Setup,
      Dust.Bridge.Discovery
    ]

    opts = [strategy: :rest_for_one, name: Dust.Bridge.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
