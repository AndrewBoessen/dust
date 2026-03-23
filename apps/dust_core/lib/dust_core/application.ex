defmodule Dust.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir =
      Application.get_env(:dust_core, :fitness_path, Path.expand("~/.dust/fitness_models"))

    children = [
      {Dust.Core.KeyStore, []},
      {CubDB, data_dir: data_dir, name: Dust.Core.Database},
      {Dust.Core.Fitness.ModelStore, [db: Dust.Core.Database]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Core.Supervisor)
  end
end
