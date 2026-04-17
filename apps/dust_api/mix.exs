defmodule Dust.Api.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust_api,
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
      mod: {Dust.Api.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:websock_adapter, "~> 0.5"},
      {:dust_daemon, in_umbrella: true},
      {:dust_core, in_umbrella: true},
      {:dust_mesh, in_umbrella: true},
      {:dust_bridge, in_umbrella: true},
      {:dust_utilities, in_umbrella: true}
    ]
  end
end
