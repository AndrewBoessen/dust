defmodule Dust.Ui.Application do
  @moduledoc """
  OTP application for the Dust web UI (Phoenix LiveView).

  Resolves the runtime bind/port from `Dust.Utilities.Config`, ensures a
  persistent `secret_key_base` exists on disk, then starts the Phoenix
  PubSub server, telemetry supervisor, and the endpoint under supervision.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    configure_endpoint!()

    children = [
      Dust.Ui.Telemetry,
      {Phoenix.PubSub, name: Dust.Ui.PubSub},
      Dust.Ui.Endpoint
    ]

    Logger.info(
      "Dust.Ui: starting on http://#{Dust.Utilities.Config.ui_bind()}:#{Dust.Utilities.Config.ui_port()}"
    )

    opts = [strategy: :one_for_one, name: Dust.Ui.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Dust.Ui.Endpoint.config_change(changed, removed)
    :ok
  end

  # Resolve runtime config (port, bind, secret_key_base) into the endpoint env
  # before the endpoint child boots.
  defp configure_endpoint!() do
    port = Dust.Utilities.Config.ui_port()
    ip = parse_bind(Dust.Utilities.Config.ui_bind())
    secret = ensure_secret_key_base!()

    existing = Application.get_env(:dust_ui, Dust.Ui.Endpoint, [])

    http =
      existing
      |> Keyword.get(:http, [])
      |> Keyword.put(:ip, ip)
      |> Keyword.put(:port, port)

    merged =
      existing
      |> Keyword.put(:http, http)
      |> Keyword.put(:secret_key_base, secret)
      # The UI exists to be served — start the HTTP listener unconditionally.
      # Test env keeps :server false unless explicitly opted in to avoid port
      # collisions during async test runs.
      |> Keyword.put_new(:server, true)

    Application.put_env(:dust_ui, Dust.Ui.Endpoint, merged)
  end

  defp parse_bind(bind_str) do
    case :inet.parse_address(to_charlist(bind_str)) do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  # Persist a 64-byte hex secret to <persist_dir>/ui_secret_key_base on first
  # boot. Reused on subsequent boots so signed sessions survive restarts.
  defp ensure_secret_key_base!() do
    path = Path.join(Dust.Utilities.Config.persist_dir(), "ui_secret_key_base")

    case File.read(path) do
      {:ok, contents} ->
        secret = String.trim(contents)

        if byte_size(secret) >= 64 do
          secret
        else
          write_secret!(path)
        end

      {:error, :enoent} ->
        write_secret!(path)
    end
  end

  defp write_secret!(path) do
    secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, secret)
    _ = File.chmod(path, 0o600)
    secret
  end
end
