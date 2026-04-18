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
      start_permanent: false,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end

  defp escript do
    [
      main_module: Dust.CLI,
      name: "dustctl",
      emu_args: "-noinput"
    ]
  end
end
