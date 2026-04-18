defmodule Dust.Api.Application do
  @moduledoc """
  OTP Application for the Dust API subsystem.

  Starts the Bandit HTTP server under supervision, binding to the
  address configured via `Dust.Utilities.Config.api_bind/0` and
  `Dust.Utilities.Config.api_port/0`.

  Children:

  1. `Bandit` — pure-Elixir HTTP/1.1 + HTTP/2 server running `Dust.Api.Router`.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    port = Dust.Utilities.Config.api_port()
    bind = parse_bind_address(Dust.Utilities.Config.api_bind())

    # Ensure the API token exists on disk
    Dust.Api.Auth.ensure_token!()

    children = [
      {Bandit, plug: Dust.Api.Router, port: port, ip: bind}
    ]

    Logger.info("Dust.Api: starting HTTP server on #{format_bind(bind)}:#{port}")

    Supervisor.start_link(children, strategy: :one_for_one, name: Dust.Api.Supervisor)
  end

  @spec parse_bind_address(String.t()) :: :inet.ip_address()
  defp parse_bind_address(bind_str) do
    case :inet.parse_address(to_charlist(bind_str)) do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  @spec format_bind(:inet.ip_address()) :: String.t()
  defp format_bind(ip) do
    ip |> :inet.ntoa() |> to_string()
  end
end
