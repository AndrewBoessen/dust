import Config

# Default master key file location
config :dust_core, :key_path, Path.expand("~/.dust/master.key")

# Default node fitness model db file location
config :dust_core, :fitness_path, Path.expand("~/.dust/fitness_models")

# Default mesh shared map db file location
config :dust_mesh, :data_dir, Path.expand("~/.dust/dust_mesh_db")
