import Config

# Dust persist file root directory
config :dust_utilities, :persist_dir, Path.join(System.user_home!(), ".dust")
