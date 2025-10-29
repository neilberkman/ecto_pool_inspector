ExUnit.start()

# For E2E tests that spawn tasks, we need shared mode
# Regular unit tests can still use manual mode
Ecto.Adapters.SQL.Sandbox.mode(InspectorTestHarness.Repo, {:shared, self()})

# Trigger pool discovery by running a throwaway query
# This ensures EctoPoolInspector discovers the pool PID immediately
Task.start(fn ->
  try do
    InspectorTestHarness.Repo.query("SELECT 1")
  rescue
    _ -> :ok
  end
end)

# Give it a moment to register
Process.sleep(100)
