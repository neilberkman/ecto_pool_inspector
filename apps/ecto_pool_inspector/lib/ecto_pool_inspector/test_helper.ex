defmodule EctoPoolInspector.TestHelper do
  @moduledoc """
  Test utilities for simulating pool exhaustion.

  This module provides helpers for testing pool monitoring by intentionally
  exhausting connection pools in controlled ways.

  ## Usage

      # In your test
      tasks = EctoPoolInspector.TestHelper.exhaust_pool(MyApp.Repo, 8)

      # ... perform tests while pool is exhausted ...

      # Clean up
      EctoPoolInspector.TestHelper.cleanup_tasks(tasks)
  """

  @doc """
  Exhausts a pool by checking out multiple connections and holding them.

  Returns a list of tasks that are holding the connections. You must call
  `cleanup_tasks/1` to release them.

  ## Parameters

    * `repo` - The Ecto repo whose pool to exhaust
    * `count` - Number of connections to hold

  ## Examples

      tasks = EctoPoolInspector.TestHelper.exhaust_pool(MyApp.Repo, 8)
      # Pool is now exhausted
      EctoPoolInspector.TestHelper.cleanup_tasks(tasks)
  """
  def exhaust_pool(repo, count) do
    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          # Use Ecto.Repo.checkout to actually hold a connection
          repo.checkout(fn ->
            # Keep the connection checked out
            receive do
              :release -> :ok
            end
          end)
        end)
      end

    # Wait for checkouts to register
    Process.sleep(100)

    # Return task refs for cleanup
    tasks
  end

  @doc """
  Releases connections held by tasks from `exhaust_pool/2`.

  ## Parameters

    * `tasks` - List of tasks returned by `exhaust_pool/2`

  ## Examples

      tasks = EctoPoolInspector.TestHelper.exhaust_pool(MyApp.Repo, 8)
      EctoPoolInspector.TestHelper.cleanup_tasks(tasks)
  """
  def cleanup_tasks(tasks) do
    # Send release message to each task
    Enum.each(tasks, fn task ->
      send(task.pid, :release)
    end)

    # Then wait for them to complete
    Enum.each(tasks, &Task.await(&1, 5_000))
  end

  @doc """
  Exhausts a pool using transactions instead of direct checkout.

  This is an alternative approach that uses Ecto's transaction mechanism
  to hold connections.

  ## Parameters

    * `repo` - The Ecto repo whose pool to exhaust
    * `count` - Number of connections to hold

  ## Examples

      tasks = EctoPoolInspector.TestHelper.exhaust_pool_with_transactions(MyApp.Repo, 8)
      # Pool is now exhausted
      EctoPoolInspector.TestHelper.cleanup_tasks(tasks)
  """
  def exhaust_pool_with_transactions(repo, count) do
    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          repo.transaction(fn ->
            # Hold the transaction open
            receive do
              :release -> :ok
            end
          end)
        end)
      end

    # Wait for transactions to register
    Process.sleep(100)

    tasks
  end
end
