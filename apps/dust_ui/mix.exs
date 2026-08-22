defmodule Dust.Ui.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust_ui,
      version: "0.2.2",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Dust.Ui.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:floki, ">= 0.30.0", only: :test},
      {:dust_daemon, in_umbrella: true},
      {:dust_core, in_umbrella: true},
      {:dust_mesh, in_umbrella: true},
      {:dust_bridge, in_umbrella: true},
      {:dust_utilities, in_umbrella: true}
    ]
  end

  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind dust_ui", "esbuild dust_ui"],
      "assets.deploy": [
        "tailwind dust_ui --minify",
        "esbuild dust_ui --minify",
        "phx.digest"
      ]
    ]
  end
end
