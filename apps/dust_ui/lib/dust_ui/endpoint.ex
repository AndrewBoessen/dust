defmodule Dust.Ui.Endpoint do
  use Phoenix.Endpoint, otp_app: :dust_ui

  @session_options [
    store: :cookie,
    key: "_dust_ui_key",
    signing_salt: "dust_ui_sess",
    same_site: "Lax",
    max_age: 60 * 60 * 24
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :dust_ui,
    gzip: false,
    only: Dust.Ui.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug Dust.Ui.Router
end
