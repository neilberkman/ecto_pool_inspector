defmodule InspectorTestHarness.E2E.Scenario4ClusterWideTest do
  use ExUnit.Case, async: false

  alias InspectorTestHarness.Repo

  @moduletag :e2e
  @moduletag :cluster

  @tag :skip
  # TODO: Multi-node testing requires more complex setup with distributed Erlang
  # This test demonstrates the intended behavior but needs proper node spawning
  describe "Scenario 4: Cluster-Wide RPC" do
    test "aggregates snapshots from multiple nodes" do
      # This test requires:
      # 1. Starting a second Erlang node
      # 2. Connecting nodes via distributed Erlang
      # 3. Ensuring both nodes have the harness application running
      #
      # Implementation sketch:
      #   {:ok, node2} = :slave.start_link(:"127.0.0.1", :test2)
      #   :rpc.call(node2, Application, :ensure_all_started, [:inspector_test_harness])
      #
      # For now, we test the single-node case to verify the API works
      
      # GIVEN: Some connections on local node
      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Repo.transaction(fn ->
              Process.sleep(2_000)
            end)
          end)
        end

      Process.sleep(500)

      # WHEN: We call the cluster-wide API with :all
      result = EctoPoolInspector.capture_snapshot(Repo, :all, :cluster_test)

      # THEN: We should get a map with node() as key
      assert is_map(result)
      assert Map.has_key?(result, node())

      snapshot = Map.get(result, node())
      assert snapshot.total_connections == 3

      # Clean up
      Task.await_many(tasks, 10_000)
    end

    test "supports targeting specific nodes" do
      # GIVEN: Connections on local node
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Repo.transaction(fn ->
              Process.sleep(2_000)
            end)
          end)
        end

      Process.sleep(500)

      # WHEN: We target only the local node
      result = EctoPoolInspector.capture_snapshot(Repo, [node()], :targeted_test)

      # THEN: We should get results for just that node
      assert is_map(result)
      assert map_size(result) == 1
      assert Map.has_key?(result, node())

      # Clean up
      Task.await_many(tasks, 10_000)
    end

    test "local scope returns single snapshot, not map" do
      # GIVEN: Connections on local node
      task =
        Task.async(fn ->
          Repo.transaction(fn ->
            Process.sleep(2_000)
          end)
        end)

      Process.sleep(500)

      # WHEN: We use :local scope
      {:ok, snapshot} = EctoPoolInspector.capture_snapshot(Repo, :local, :local_test)

      # THEN: We get a snapshot struct, not a map
      assert is_map(snapshot)
      assert snapshot.node == node()
      assert snapshot.total_connections == 1

      # Clean up
      Task.await(task, 10_000)
    end
  end

  describe "Multi-pool composite key validation" do
    test "same process can hold connections from multiple pools (if configured)" do
      # This test validates the composite key fix: {{client_pid, pool_pid}, ...}
      # For now we only have one pool, but the schema supports multiple
      
      # GIVEN: A process checks out a connection
      task =
        Task.async(fn ->
          Repo.transaction(fn ->
            # This process now holds 1 connection from Repo
            # If we had a second repo (ReadReplica), we could check out from both
            # and verify the StateTracker tracks them separately
            Process.sleep(2_000)
          end)
        end)

      Process.sleep(500)

      # WHEN: We capture a snapshot
      {:ok, snapshot} = EctoPoolInspector.capture_snapshot(Repo, :local, :composite_key_test)

      # THEN: We should see 1 connection tracked correctly
      assert snapshot.total_connections == 1
      conn = List.first(snapshot.connections)
      
      # Verify the connection is tracked with correct pool_pid
      assert conn.pool_pid == get_pool_pid()

      # Clean up
      Task.await(task, 10_000)
    end
  end

  # Helper to get the pool PID
  defp get_pool_pid do
    {:ok, pool_pid} = GenServer.call(EctoPoolInspector.StateTracker, {:get_pool_pid, Repo})
    pool_pid
  end
end
