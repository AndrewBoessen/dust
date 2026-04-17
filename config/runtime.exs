import Config

# ── Runtime overrides (applied after compile-time config) ──────────────
#
# These environment variables are read when the release boots and override
# any values set in config.exs / dev.exs / prod.exs.

api_port =
  if port_str = System.get_env("DUST_API_PORT") do
    String.to_integer(port_str)
  end

api_bind = System.get_env("DUST_API_BIND")
persist_dir = System.get_env("DUST_DATA_DIR")

runtime_overrides =
  %{}
  |> then(fn m -> if api_port, do: Map.put(m, :api_port, api_port), else: m end)
  |> then(fn m -> if api_bind, do: Map.put(m, :api_bind, api_bind), else: m end)
  |> then(fn m -> if persist_dir, do: Map.put(m, :persist_dir, persist_dir), else: m end)

if map_size(runtime_overrides) > 0 do
  existing = Application.get_env(:dust_utilities, :config, %{})
  config :dust_utilities, :config, Map.merge(existing, runtime_overrides)
end
