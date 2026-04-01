defmodule Dust.Storage.Application do
  @moduledoc """
  OTP Application for the Dust Storage subsystem.

  Starts the RocksDB-backed shard store under supervision. The database
  is opened at the path returned by `Dust.Utilities.File.storage_db_dir/0`
  (defaults to `~/.dust/storage_db/`).

  Children:

  1. `Dust.Storage.RocksBackend` — GenServer owning the RocksDB handle.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Dust.Storage.RocksBackend
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Storage.Supervisor)
  end
end
