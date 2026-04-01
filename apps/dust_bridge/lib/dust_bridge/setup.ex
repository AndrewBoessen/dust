defmodule Dust.Bridge.Setup do
  @moduledoc """
  One-shot startup task that bootstraps the node's Tailscale integration.

  Runs as a supervised `Task` after `Dust.Bridge` has started. It:

  1. Initializes the OTP cookie via `Dust.Bridge.Secrets.setup/0`.
  2. Exposes the EPMD port (4369) on the node's Tailscale IP so that
     peers can discover this node.
  3. Exposes the Erlang distribution port (9000) on the Tailscale IP so
     that peers can form a cluster connection.

  A 1-second delay at the start gives the Go sidecar time to finish its
  own initialization before receiving commands.
  """
  use Task
  require Logger

  @doc false
  @spec start_link(term()) :: {:ok, pid()}
  def start_link(_arg) do
    Task.start_link(__MODULE__, :run, [])
  end

  @doc """
  Executes the setup sequence.

  This function is invoked automatically by `Task.start_link/3` and
  should not be called directly.
  """
  @spec run() :: :ok
  def run() do
    Dust.Bridge.Secrets.setup()

    Logger.info("Bridge Setup: Informing tsnet sidecar to expose EPMD and Distribution ports")

    case Dust.Bridge.expose(4369) do
      :ok -> Logger.info("Bridge Setup: Exposed EPMD port 4369 over Tailscale")
      err -> Logger.error("Bridge Setup: Error exposing 4369: #{inspect(err)}")
    end

    case Dust.Bridge.expose(9000) do
      :ok -> Logger.info("Bridge Setup: Exposed Distribution port 9000 over Tailscale")
      err -> Logger.error("Bridge Setup: Error exposing 9000: #{inspect(err)}")
    end

    :ok
  end
end
