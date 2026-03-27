defmodule Dust.Bridge.Setup do
  @moduledoc """
  Task to configure the tsnet sidecar for Erlang distribution over Tailscale.
  """
  use Task
  require Logger

  def start_link(_arg) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run() do
    # Give the bridge a short moment to fully initialize
    Process.sleep(1000)

    Dust.Bridge.Secrets.setup()

    Logger.info("Bridge Setup: Informing tsnet sidecar to expose EPMD and Distribution ports")
    # Tell tsnet sidecar to expose incoming Erlang distribution ports
    case Dust.Bridge.expose(4369) do
      :ok -> Logger.info("Bridge Setup: Exposed EPMD port 4369 over Tailscale")
      err -> Logger.error("Bridge Setup: Error exposing 4369: #{inspect(err)}")
    end

    case Dust.Bridge.expose(9000) do
      :ok -> Logger.info("Bridge Setup: Exposed Distribution port 9000 over Tailscale")
      err -> Logger.error("Bridge Setup: Error exposing 9000: #{inspect(err)}")
    end
  end
end
