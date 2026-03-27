import Config

# Hide info logs
config :logger, level: :error

# Use fast Argon2 hashing for tests only
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8

tmp_dir = System.tmp_dir!()

# Dust persist file root directory
config :dust_utilities, :persist_dir, Path.join(System.tmp_dir!(), "dust_test")
