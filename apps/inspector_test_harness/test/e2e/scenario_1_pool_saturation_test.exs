defmodule InspectorTestHarness.E2E.Scenario1PoolSaturationTest do
  use ExUnit.Case, async: false

  alias InspectorTestHarness.Repo

  @moduletag :e2e

  setup do
    # Clear any existing snapshots
    :timer.sleep(100)
    :ok
  end

  describe "Scenario 1: Pool Saturation Trigger" do
    test "captures snapshot when pool is saturated" do
      # GIVEN: Pool is idle with no snapshots
      snapshots_before = EctoPoolInspector.list_snapshots(Repo, :local)
      assert snapshots_before == []

      # WHEN: We exhaust the pool by checking out 5 connections
      # Pool size is 5, saturation trigger is 0.8 (4 connections)
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Repo.transaction(fn ->
              # Hold connection for 3 seconds
              Process.sleep(3_000)
            end)
          end)
        end

      # Wait for saturation poller to run (configured at 100ms interval)
      # and for snapshot capture (min interval is 1000ms)
      Process.sleep(1_500)

      # THEN: A snapshot should have been captured
      snapshots_after = EctoPoolInspector.list_snapshots(Repo, :local)

      assert length(snapshots_after) >= 1, "Expected at least one snapshot to be captured"

      snapshot = List.first(snapshots_after)

      # Verify snapshot metadata
      assert snapshot.reason == :pool_saturation
      assert snapshot.pool_size == 5
      assert snapshot.total_connections == 5
      assert snapshot.node == node()

      # Verify we captured connections (we configured capture_stack_traces: :all)
      assert snapshot.sampled_connections == 5
      assert length(snapshot.connections) == 5

      # Verify connection details
      conn = List.first(snapshot.connections)
      assert is_pid(conn.pid)
      assert conn.pool_pid == get_pool_pid()
      assert is_integer(conn.held_for_ms)
      assert conn.depth == 1

      # Verify stack traces were captured
      assert is_list(conn.stack_trace)
      assert conn.context =~ "Task"

      # Clean up: wait for tasks to finish
      Task.await_many(tasks, 10_000)
    end

    test "tracks depth correctly for nested transactions" do
      # GIVEN: We start a nested transaction
      task =
        Task.async(fn ->
          Repo.transaction(fn ->
            # Depth = 1
            Repo.transaction(fn ->
              # Depth = 2
              Process.sleep(2_000)
            end)
          end)
        end)

      # Wait for checkout to be registered
      Process.sleep(500)

      # WHEN: We manually capture a snapshot
      {:ok, snapshot} = EctoPoolInspector.capture_snapshot(Repo, :local, :manual_depth_test)

      # THEN: The connection should show depth = 2
      assert snapshot.total_connections == 1
      conn = List.first(snapshot.connections)
      assert conn.depth == 2

      # Clean up
      Task.await(task, 10_000)
    end

    test "cleans up when process dies holding connection" do
      # GIVEN: We spawn a process that checks out and crashes
      spawn(fn ->
        Repo.transaction(fn ->
          Process.sleep(100)
          raise "Intentional crash"
        end)
      end)

      # Wait for crash and cleanup
      Process.sleep(500)

      # WHEN: We capture a snapshot
      {:ok, snapshot} = EctoPoolInspector.capture_snapshot(Repo, :local, :manual_cleanup_test)

      # THEN: The dead process should not appear in connections
      assert snapshot.total_connections == 0
    end
  end

  # Helper to get the pool PID for assertions
  defp get_pool_pid do
    {:ok, pool_pid} = GenServer.call(EctoPoolInspector.StateTracker, {:get_pool_pid, Repo})
    pool_pid
  end
end
