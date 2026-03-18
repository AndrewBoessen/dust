import Config

# Default master key file location
config :dust_core, :key_path, Path.expand("~/.dust/master.key")

# Default node fitness model file location
config :dust_core, :fitness_path, Path.expand("~/.dust/fitness_models.bin")
