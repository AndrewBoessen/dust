import Config

# Dust persist file root directory
config :dust_utilities, :config, %{
  persist_dir: Path.join(File.cwd!(), "dust_dev")
}
