import Config

# Use a temporary key path for tests so we don't pollute ~/.dust/
config :core,
       :key_path,
       Path.join(System.tmp_dir!(), "dust_test_master_#{System.unique_integer([:positive])}.key")

# Use fast Argon2 hashing for tests only
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8
