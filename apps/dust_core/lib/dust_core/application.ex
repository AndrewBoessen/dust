defmodule Dust.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:dust_utilities, :persist_dir)
    key_path = Path.join(data_dir, "master.key")
    fitness_model_path = Path.join(data_dir, "fitness_models")

    children = [
      {Dust.Core.KeyStore, [key_path: key_path]},
      {CubDB, data_dir: fitness_model_path, name: Dust.Core.Database},
      {Dust.Core.Fitness.ModelStore, [db: Dust.Core.Database]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Core.Supervisor)
  end
end
