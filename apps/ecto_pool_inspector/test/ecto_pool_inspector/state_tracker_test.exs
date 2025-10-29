defmodule EctoPoolInspector.StateTrackerTest do
  use ExUnit.Case, async: false

  alias EctoPoolInspector.StateTracker

  setup do
    # Use the existing StateTracker process started by the application
    {:ok, tracker: StateTracker}
  end

  describe "checkout/checkin tracking" do
    test "tracks simple checkout and checkin", %{tracker: tracker} do
      client_pid = self()
      pool_pid = spawn(fn -> :timer.sleep(:infinity) end)

      # Simulate checkout
      GenServer.cast(tracker, {:checkout, client_pid, pool_pid})
      Process.sleep(50)

      # Verify count increased
      count = GenServer.call(tracker, {:get_checkout_count, pool_pid})
      assert count == 1

      # Simulate checkin
      GenServer.cast(tracker, {:checkin, client_pid, pool_pid})
      Process.sleep(50)

      # Verify count decreased
      count = GenServer.call(tracker, {:get_checkout_count, pool_pid})
      assert count == 0

      # Clean up
      Process.exit(pool_pid, :kill)
    end

    test "tracks nested checkouts (depth)", %{tracker: tracker} do
      client_pid = self()
      pool_pid = spawn(fn -> :timer.sleep(:infinity) end)

      # First checkout
      GenServer.cast(tracker, {:checkout, client_pid, pool_pid})
      Process.sleep(50)

      count1 = GenServer.call(tracker, {:get_checkout_count, pool_pid})
      assert count1 == 1

      # Nested checkout
      GenServer.cast(tracker, {:checkout, client_pid, pool_pid})
      Process.sleep(50)

      # Count should still be 1 (same connection, nested transaction)
      count2 = GenServer.call(tracker, {:get_checkout_count, pool_pid})
      assert count2 == 1

      # First checkin (depth 2 -> 1)
      GenServer.cast(tracker, {:checkin, client_pid, pool_pid})
      Process.sleep(50)

      # Should still be checked out
      count3 = GenServer.call(tracker, {:get_checkout_count, pool_pid})
      assert count3 == 1

      # Final checkin (depth 1 -> 0)
      GenServer.cast(tracker, {:checkin, client_pid, pool_pid})
      Process.sleep(50)

      # Now should be 0
      count4 = GenServer.call(tracker, {:get_checkout_count, pool_pid})
      assert count4 == 0

      # Clean up
      Process.exit(pool_pid, :kill)
    end

    test "cleans up when client process dies", %{tracker: tracker} do
      pool_pid = spawn(fn -> :timer.sleep(:infinity) end)

      # Spawn a client that checks out and then dies
      _client_pid =
        spawn(fn ->
          GenServer.cast(tracker, {:checkout, self(), pool_pid})
          Process.sleep(50)
          # Process exits here
        end)

      # Wait for checkout to register
      Process.sleep(100)

      # Wait for process to die and cleanup to happen
      Process.sleep(200)

      # Count should be 0 (cleanup happened)
      count = GenServer.call(tracker, {:get_checkout_count, pool_pid})
      assert count == 0

      # Clean up
      Process.exit(pool_pid, :kill)
    end
  end

  describe "pool discovery" do
    test "registers repo to pool mapping", %{tracker: tracker} do
      pool_pid = spawn(fn -> :timer.sleep(:infinity) end)

      # Discover pool
      GenServer.cast(tracker, {:discover_pool, TestRepo, pool_pid})
      Process.sleep(50)

      # Should be able to retrieve it
      assert {:ok, ^pool_pid} = GenServer.call(tracker, {:get_pool_pid, TestRepo})

      # Clean up
      Process.exit(pool_pid, :kill)
    end

    test "returns error for unknown repo", %{tracker: tracker} do
      assert {:error, :pool_not_discovered} =
               GenServer.call(tracker, {:get_pool_pid, UnknownRepo})
    end
  end

  describe "snapshot capture" do
    test "captures snapshot with no connections", %{tracker: tracker} do
      pool_pid = spawn(fn -> :timer.sleep(:infinity) end)

      config = [
        capture_stack_traces: :none,
        pool_size: 10
      ]

      assert {:ok, snapshot} = GenServer.call(tracker, {:capture_snapshot, pool_pid, config})

      assert snapshot.pool_pid == pool_pid
      assert snapshot.node == node()
      assert snapshot.total_connections == 0
      assert snapshot.sampled_connections == 0
      assert snapshot.connections == []
      assert snapshot.pool_size == 10

      # Clean up
      Process.exit(pool_pid, :kill)
    end

    test "captures snapshot with active connections", %{tracker: tracker} do
      pool_pid = spawn(fn -> :timer.sleep(:infinity) end)

      # Create some client processes holding connections
      client1 = spawn(fn -> :timer.sleep(:infinity) end)
      client2 = spawn(fn -> :timer.sleep(:infinity) end)

      GenServer.cast(tracker, {:checkout, client1, pool_pid})
      GenServer.cast(tracker, {:checkout, client2, pool_pid})
      Process.sleep(100)

      config = [
        capture_stack_traces: :all,
        stack_trace_timeout: 1000,
        stack_trace_concurrency: 10,
        pool_size: 10
      ]

      assert {:ok, snapshot} =
               GenServer.call(tracker, {:capture_snapshot, pool_pid, config}, 5000)

      assert snapshot.total_connections == 2
      assert snapshot.sampled_connections == 2
      assert length(snapshot.connections) == 2

      # Verify connection details
      conn = List.first(snapshot.connections)
      assert conn.pid in [client1, client2]
      assert conn.pool_pid == pool_pid
      assert is_integer(conn.held_for_ms)
      assert conn.depth == 1

      # Clean up
      Process.exit(pool_pid, :kill)
      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end
end
