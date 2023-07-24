defmodule Sanity.Listen.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :sanity_listen,
      version: @version,
      elixir: "~> 1.13",
      description: "Listen for changes to Sanity CMS documents in realtime.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/balexand/sanity_listen"}
      ],
      docs: [
        extras: ["README.md"],
        main: "readme",
        source_ref: "v#{@version}",
        source_url: "https://github.com/balexand/sanity_listen"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:castore, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:mint, "~> 1.0"},
      {:nimble_options, "~> 0.5 or ~> 1.0"},
      {:sanity, "~> 1.3"},

      # dev/test
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:mox, ">= 1.0.0", only: :test}
    ]
  end
end
