defmodule DustDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust_daemon,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DustDaemon.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dust_core, in_umbrella: true},
      {:dust_mesh, in_umbrella: true},
      {:dust_storage, in_umbrella: true},
      {:dust_bridge, in_umbrella: true},
      {:dust_utilities, in_umbrella: true}
    ]
  end
end
