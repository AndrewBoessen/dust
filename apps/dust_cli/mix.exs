defmodule Dust.Cli.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: true,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {Dust.CLI.Application, []},
      extra_applications: [:logger, :inets, :ssl, :crypto]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:burrito, "~> 1.0"}
    ]
  end

  defp releases do
    [
      dustctl: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64:   [os: :linux,   cpu: :x86_64],
            linux_aarch64:  [os: :linux,   cpu: :aarch64],
            macos_x86_64:   [os: :darwin,  cpu: :x86_64],
            macos_aarch64:  [os: :darwin,  cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
