defmodule InspectorTestHarnessWeb.TestController do
  use InspectorTestHarnessWeb, :controller

  @doc """
  Endpoint: GET /test/hold-connections/:count

  Spawns N tasks that each check out a connection and hold it for 5 seconds.
  This simulates long-running transactions that exhaust the pool.

  Used to test:
  - Pool saturation triggers
  - Stack trace capture
  - Process monitoring and cleanup
  """
  def hold_connections(conn, %{"count" => count_str}) do
    count = String.to_integer(count_str)

    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          InspectorTestHarness.Repo.transaction(fn ->
            # Hold connection for 5 seconds
            Process.sleep(5_000)
          end)
        end)
      end

    # Wait for all tasks to complete
    Task.await_many(tasks, 10_000)

    json(conn, %{status: "ok", held_connections: count})
  end

  @doc """
  Endpoint: GET /test/crash-while-holding

  Spawns a process that checks out a connection and then crashes.
  Used to test process monitoring and leak detection.
  """
  def crash_while_holding(conn, _params) do
    # Spawn and link so crash is isolated
    Task.start(fn ->
      InspectorTestHarness.Repo.transaction(fn ->
        # Ensure checkout is registered
        Process.sleep(100)
        raise "Intentional crash for testing"
      end)
    end)

    # Give time for crash and cleanup
    Process.sleep(500)

    json(conn, %{status: "ok", message: "Process crashed"})
  end

  @doc """
  Endpoint: GET /test/nested-transaction

  Executes nested transactions to test depth tracking.
  """
  def nested_transaction(conn, _params) do
    result =
      InspectorTestHarness.Repo.transaction(fn ->
        # Depth = 1
        InspectorTestHarness.Repo.transaction(fn ->
          # Depth = 2
          Process.sleep(2_000)
          :ok
        end)
      end)

    json(conn, %{status: "ok", result: inspect(result)})
  end

  @doc """
  Endpoint: GET /test/trigger-snapshot

  Helper endpoint to manually trigger a snapshot for inspection.
  """
  def trigger_snapshot(conn, _params) do
    result = EctoPoolInspector.capture_snapshot(InspectorTestHarness.Repo, :local, :manual_test)
    json(conn, %{status: "ok", snapshot: result})
  end

  @doc """
  Endpoint: GET /test/health

  Simple health check endpoint.
  """
  def health(conn, _params) do
    json(conn, %{status: "ok", pool_size: 5})
  end
end
