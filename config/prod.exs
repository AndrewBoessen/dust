import Config

# Dust persist file root directory
config :dust_utilities, :persist_dir, Path.join(System.user_home!(), ".dust")

# ── Web UI prod settings ───────────────────────────────────────────────
# secret_key_base is generated and persisted on first boot by
# Dust.Ui.Application — see <persist_dir>/ui_secret_key_base.
config :dust_ui, Dust.Ui.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true
