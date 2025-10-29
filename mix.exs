defmodule EctoPoolInspectorUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [
        "test.all": :test,
        "test.unit": :test,
        "test.e2e": :test
      ]
    ]
  end

  # Dependencies listed here are available to all child apps
  defp deps do
    []
  end

  # Aliases for running tests across the umbrella
  defp aliases do
    [
      "test.all": ["cmd mix test", "cmd --app inspector_test_harness mix test"],
      "test.unit": ["cmd --app ecto_pool_inspector mix test"],
      "test.e2e": ["cmd --app inspector_test_harness mix test test/e2e/"]
    ]
  end
end
