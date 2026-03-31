defmodule Dust.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    key_path = Dust.Utilities.File.master_key_file()
    fitness_model_path = Dust.Utilities.File.fitness_models_dir()

    children = [
      {Dust.Core.KeyStore, [key_path: key_path]},
      {CubDB, data_dir: fitness_model_path, name: Dust.Core.Database},
      {Dust.Core.Fitness.ModelStore, [db: Dust.Core.Database]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Core.Supervisor)
  end
end
