import Config

# Hide info logs
config :logger, level: :error

# Use fast Argon2 hashing for tests only
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8

# Disable tsnet sidecar in tests
config :dust_bridge, :start_sidecar, false

# Dust persist file root directory; bind the HTTP API to a random free port
# in tests so it never collides with a running dust daemon on the dev box.
config :dust_utilities, :config, %{
  persist_dir: Path.join(System.tmp_dir!(), "dust_test"),
  api_port: 14884,
  ui_port: 14885
}

# ── Web UI test settings ───────────────────────────────────────────────
config :dust_ui, Dust.Ui.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 14885],
  secret_key_base: "test_secret_key_base_placeholder_must_be_at_least_64_chars_long_xx",
  server: false
