defmodule Dust.Utilities.File do
  @moduledoc """
  Centralized file path management for persistent data structures.

  Defines specific physical storage paths (directories and filenames)
  so the rest of the umbrella applications can rely on a single
  authoritative source for disk I/O destinations.
  """

  @master_key_file "master.key"
  @fitness_model_dir "fitness_models"
  @mesh_db_dir "mesh_db"
  @ts_state_root "ts_state"
  @node_ts_state_prefix "tsnet-state"
  @secrets_file "secrets.json"
  @default_node_name "unknown"

  @doc """
  Returns the base persistence directory.
  Defaults to evaluating the `~/.dust` path via System.user_home!().
  """
  def persist_dir do
    Application.get_env(
      :dust_utilities,
      :persist_dir,
      Path.join([System.user_home!(), ".dust"])
    )
  end

  @doc "Absolute path to the master.key file"
  def master_key_file do
    Path.join(persist_dir(), @master_key_file)
  end

  @doc "Absolute path to the fitness_models directory"
  def fitness_models_dir do
    Path.join(persist_dir(), @fitness_model_dir)
  end

  @doc "Absolute path to the mesh_db directory"
  def mesh_db_dir do
    Path.join(persist_dir(), @mesh_db_dir)
  end

  @doc """
  Absolute path to the tsnet state directory.
  Defaults to evaluating the node_prefix.
  """
  def ts_state_dir(prefix \\ node_prefix()) do
    Path.join([persist_dir(), @ts_state_root, "#{@node_ts_state_prefix}-#{prefix}"])
  end

  @doc """
  Absolute path to the secrets.json file.
  Defaults to evaluating the node_prefix.
  """
  def secrets_file(prefix \\ node_prefix()) do
    Path.join(ts_state_dir(prefix), @secrets_file)
  end

  # Helper to identify uniqueness in dev clusters via the node name.
  defp node_prefix do
    Node.self()
    |> to_string()
    |> String.split("@")
    |> List.first() || @default_node_name
  end
end
