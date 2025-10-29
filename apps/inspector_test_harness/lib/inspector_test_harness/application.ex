defmodule InspectorTestHarness.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      InspectorTestHarnessWeb.Telemetry,
      InspectorTestHarness.Repo,
      # NOTE: EctoPoolInspector auto-starts as a dependency application
      # It will start after Repo due to OTP application boot order
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name: InspectorTestHarness.ClusterSupervisor]]},
      {DNSCluster, query: Application.get_env(:inspector_test_harness, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: InspectorTestHarness.PubSub},
      # Start a worker by calling: InspectorTestHarness.Worker.start_link(arg)
      # {InspectorTestHarness.Worker, arg},
      # Start to serve requests, typically the last entry
      InspectorTestHarnessWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InspectorTestHarness.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InspectorTestHarnessWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
