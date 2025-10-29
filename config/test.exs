import Config

# Configure your database with TINY pool for E2E exhaustion testing
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :inspector_test_harness, InspectorTestHarness.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "inspector_test_harness_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # CRITICAL: Tiny pool for testing exhaustion (5 connections)
  pool_size: 5,
  queue_target: 50,
  queue_interval: 100

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :inspector_test_harness, InspectorTestHarnessWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "w54nMHsBWGEU8r4dwKcG543WMt88PBUFbkCTryr4iAJGkApgFL4SHHwS2a9cAp9O",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Configure EctoPoolInspector with AGGRESSIVE triggers for E2E testing
config :ecto_pool_inspector,
  repos: [
    %{
      repo: InspectorTestHarness.Repo,
      app_name: :inspector_test_harness,
      pool_size: 5,
      triggers: [
        # Trigger at 80% = 4 out of 5 connections
        {:pool_saturation, 0.8},
        # Trigger on any query waiting >100ms for connection
        {:queue_time, 100}
      ],
      # Very short interval for fast test feedback
      snapshot_interval: 1_000,
      saturation_poll_interval: 100,
      # Capture ALL stack traces in tests
      capture_stack_traces: :all,
      stack_trace_timeout: 1000,
      stack_trace_concurrency: 10,
      max_snapshots: 50
    }
  ]

# Configure libcluster for multi-node testing
config :libcluster,
  topologies: [
    test: [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts: [
          :"test1@127.0.0.1",
          :"test2@127.0.0.1"
        ]
      ]
    ]
  ]
