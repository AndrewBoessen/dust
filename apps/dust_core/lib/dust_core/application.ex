defmodule Dust.Core.Application do
  @moduledoc """
  OTP Application for the Dust Core subsystem.

  Starts the following children:

  1. `Dust.Core.KeyStore` — master-key vault (locked until user provides password).
  2. `Dust.Core.Database` (`CubDB`) — embedded database backing the fitness model store.
  3. `Dust.Core.Fitness.ModelStore` — ETS-cached, disk-persisted NodeEMA models.
  """

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
