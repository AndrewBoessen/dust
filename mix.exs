defmodule Dust.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      name: "Dust",
      version: "0.1.2",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [{:ex_doc, "~> 0.30", only: :dev, runtime: false}]
  end

  defp releases do
    [
      dust: [
        applications: [
          dust_utilities: :permanent,
          dust_bridge: :permanent,
          dust_core: :permanent,
          dust_storage: :permanent,
          dust_mesh: :permanent,
          dust_daemon: :permanent,
          dust_api: :permanent
        ],
        strip_beams: [keep: ["Docs"]],
        cookie: "dust_cookie"
      ]
    ]
  end
end
