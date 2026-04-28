defmodule Dust.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust_core,
      version: "0.1.1",
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
      mod: {Dust.Core.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:argon2_elixir, "~> 4.1"},
      {:cubdb, "~> 2.0.2"},
      {:rs_simd, "~> 0.1", hex: :reed_solomon_simd},
      {:dust_bridge, in_umbrella: true},
      {:dust_utilities, in_umbrella: true},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
