defmodule GfdmMdb.MixProject do
  use Mix.Project

  def project do
    [
      app: :gfdm_mdb,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: [main_module: GfdmMdb.Cli],
      releases: releases(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:crypto]] ++ application_mod(Mix.env())
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  ###
  ### Helpers
  ###

  defp application_mod(:prod), do: [mod: {GfdmMdb.Application, []}]
  defp application_mod(_environment), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp releases do
    [
      gfdm_mdb: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1"},
      {:owl, "~> 0.13.1"},
      {:saxy, "~> 1.6"},
      {:burrito, "~> 1.5.0", only: :prod, runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
