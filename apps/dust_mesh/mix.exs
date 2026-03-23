defmodule Dust.Mesh.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust_mesh,
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
      mod: {Dust.Mesh.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:delta_crdt, "~> 0.6.5"},
      {:cubdb, "~> 2.0.2"},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      {:dust_core, in_umbrella: true},
      {:dust_bridge, in_umbrella: true},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
