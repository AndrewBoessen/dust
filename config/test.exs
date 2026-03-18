import Config

# Use fast Argon2 hashing for tests only
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8
