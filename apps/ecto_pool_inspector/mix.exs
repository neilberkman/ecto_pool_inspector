defmodule EctoPoolInspector.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/neilberkman/ecto_pool_inspector"

  def project do
    [
      app: :ecto_pool_inspector,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Experimental Ecto connection pool monitoring with cluster-aware snapshots (untested, not for production)",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", ".formatter.exs"],
      maintainers: ["Neil Berkman"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "EctoPoolInspector",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:ex_unit]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {EctoPoolInspector.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime dependencies
      {:ecto, "~> 3.10"},
      {:db_connection, "~> 2.4"},
      {:telemetry, "~> 1.0"},

      # Dev/Test dependencies
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:quokka, "~> 2.11", only: :dev}
    ]
  end
end
