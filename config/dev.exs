import Config

# Dust persist file root directory
config :dust_utilities, :config, %{
  persist_dir: Path.join(File.cwd!(), "dust_dev")
}

# ── Web UI dev settings ────────────────────────────────────────────────
config :dust_ui, Dust.Ui.Endpoint,
  # Generated/overwritten at runtime; this placeholder lets the endpoint compile.
  secret_key_base: "dev_only_secret_key_base_placeholder_must_be_at_least_64_chars_xxx",
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:dust_ui, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:dust_ui, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      Regex.compile!("priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$"),
      Regex.compile!("lib/dust_ui/(controllers|live|components)/.*(ex|heex)$")
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :debug_heex_annotations, true
