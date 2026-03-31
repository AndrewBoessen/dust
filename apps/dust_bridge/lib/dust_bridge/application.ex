defmodule Dust.Bridge.Application do
  @moduledoc """
  OTP Application for the Dust Bridge subsystem.

  Starts the following children in order:

  1. `Dust.Bridge.Secrets` — Agent caching the master key received during a join.
  2. `Dust.Bridge` — GenServer managing the Go `tsnet_sidecar` port.
  3. `Dust.Bridge.Setup` — One-shot task that initializes the OTP cookie and
     exposes distribution ports on the Tailscale IP.
  4. `Dust.Bridge.Discovery` — Periodic poller that connects to peer nodes
     discovered via Tailscale.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Dust.Bridge.Secrets,
      Dust.Bridge,
      Dust.Bridge.Setup,
      Dust.Bridge.Discovery
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Bridge.Supervisor)
  end
end
