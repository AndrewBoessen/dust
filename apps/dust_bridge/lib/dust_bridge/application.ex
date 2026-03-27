defmodule Dust.Bridge.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:dust_utilities, :persist_dir)
    ts_state_dir = Path.join(data_dir, "ts_state")

    children = [
      Dust.Bridge.Secrets,
      {Dust.Bridge, [ts_state_dir: ts_state_dir]},
      Dust.Bridge.Setup,
      Dust.Bridge.Discovery
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Bridge.Supervisor)
  end
end
