# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# ── Web UI (Phoenix LiveView) ──────────────────────────────────────────
config :dust_ui, Dust.Ui.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4885],
  render_errors: [
    formats: [html: Dust.Ui.ErrorHTML, json: Dust.Ui.ErrorJSON],
    layout: false
  ],
  pubsub_server: Dust.Ui.PubSub,
  live_view: [signing_salt: "dust_ui_live"]

config :phoenix, :json_library, Jason

config :esbuild,
  version: "0.21.5",
  dust_ui: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/dust_ui/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  dust_ui: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/dust_ui/assets", __DIR__)
  ]

import_config "#{config_env()}.exs"
