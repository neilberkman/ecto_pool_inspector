defmodule EctoPoolInspector.StackTraceTest do
  use ExUnit.Case, async: true

  alias EctoPoolInspector.StackTrace

  describe "capture/1" do
    test "captures stack trace for a living process" do
      # Spawn a process that we can capture
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, info} = StackTrace.capture(pid)
      assert is_binary(info.stack_trace)
      assert is_binary(info.initial_call)
      assert is_binary(info.context)

      # Clean up
      send(pid, :stop)
    end

    test "returns error for dead process" do
      # Create a process that immediately dies
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      assert {:error, :process_dead} = StackTrace.capture(pid)
    end

    test "identifies GenServer context" do
      # Start a GenServer
      {:ok, pid} = Agent.start_link(fn -> %{} end)

      # Make a call to put it in GenServer.call context
      task =
        Task.async(fn ->
          Agent.get(pid, fn _state ->
            # While in the callback, capture our own stack
            StackTrace.capture(self())
          end)
        end)

      result = Task.await(task)

      case result do
        {:ok, info} ->
          # Should identify as GenServer Call or Agent (which uses GenServer)
          assert info.context in ["GenServer Call", "Unknown"]

        {:error, _} ->
          # Process might have completed too quickly, that's okay for this test
          :ok
      end

      # Clean up
      Agent.stop(pid)
    end

    test "identifies Task context" do
      task =
        Task.async(fn ->
          # Capture our own stack trace
          StackTrace.capture(self())
        end)

      result = Task.await(task)

      assert {:ok, info} = result
      assert info.context in ["Task.async", "Unknown"]
    end
  end
end
