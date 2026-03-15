import Config

# Default master key file location (overridden in test.exs)
config :core, :key_path, Path.expand("~/.dust/master.key")
