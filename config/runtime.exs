import Config

if config_env() == :dev do
  # Dust persist file root directory
  config :dust_utilities, :persist_dir, Path.join(File.cwd!(), "dust_dev")
end
