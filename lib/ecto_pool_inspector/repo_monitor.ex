defmodule EctoPoolInspector.RepoMonitor do
  @moduledoc """
  Per-repo trigger evaluation with rate limiting.
  """

  use GenServer

  defstruct [
    :config,
    :last_snapshot_at,
    :poll_interval,
    :pool_pid,
    :pool_size,
    :repo
  ]

  def start_link({repo, config}) do
    GenServer.start_link(__MODULE__, {repo, config})
  end

  @impl true
  def init({repo, config}) do
    # Get pool size from repo config or use configured default
    pool_size = config[:pool_size] || 10

    # Discover and register the pool with StateTracker
    pool_pid = discover_pool_pid(repo)

    if pool_pid do
      GenServer.cast(EctoPoolInspector.StateTracker, {:discover_pool, repo, pool_pid})
    end

    # Attach to repo query events
    app_name = config[:app_name]

    if app_name do
      event_name = [app_name, :repo, :query]

      :telemetry.attach(
        "ecto-pool-inspector-monitor-#{repo}-#{node()}",
        event_name,
        &handle_query_event/4,
        {self(), config}
      )
    end

    # Schedule saturation check
    poll_interval = config[:saturation_poll_interval] || 10_000
    Process.send_after(self(), :check_pool_saturation, poll_interval)

    {:ok,
     %__MODULE__{
       config: config,
       last_snapshot_at: nil,
       poll_interval: poll_interval,
       pool_pid: pool_pid,
       pool_size: pool_size,
       repo: repo
     }}
  end

  # Helper to discover the pool PID from the repo's supervision tree
  defp discover_pool_pid(repo) do
    # Try to get the repo's pool from its config
    case Process.whereis(repo) do
      nil -> nil
      repo_pid -> repo_pid
    end
  end

  # Telemetry handler (fast path)
  def handle_query_event(_event, measurements, _metadata, {monitor_pid, config}) do
    # Check queue time trigger
    queue_time = measurements[:queue_time] || measurements[:idle_time]

    if queue_time && should_trigger_queue_time?(queue_time, config[:triggers] || []) do
      GenServer.cast(monitor_pid, {:trigger_snapshot, :queue_time_exceeded})
    end
  end

  @impl true
  def handle_info(:check_pool_saturation, state) do
    # Check saturation trigger
    pool_pid = state.pool_pid || get_pool_pid_from_tracker(state.repo)

    if pool_pid do
      count = GenServer.call(EctoPoolInspector.StateTracker, {:get_checkout_count, pool_pid})

      # Avoid divide by zero
      saturation =
        if state.pool_size > 0 do
          count / state.pool_size
        else
          0.0
        end

      if should_trigger_saturation?(saturation, state.config[:triggers] || []) do
        GenServer.cast(self(), {:trigger_snapshot, :pool_saturation})
      end
    end

    # Schedule next check
    Process.send_after(self(), :check_pool_saturation, state.poll_interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:trigger_snapshot, reason}, state) do
    now = DateTime.utc_now()

    if should_capture_snapshot?(state, now) do
      capture_and_store_snapshot(state, reason, now)
    else
      {:noreply, state}
    end
  end

  # Private helpers

  defp should_capture_snapshot?(state, now) do
    min_interval = state.config[:snapshot_interval] || 60_000

    case state.last_snapshot_at do
      nil -> true
      last -> DateTime.diff(now, last, :millisecond) >= min_interval
    end
  end

  defp capture_and_store_snapshot(state, reason, now) do
    pool_pid = state.pool_pid || get_pool_pid_from_tracker(state.repo)

    case capture_snapshot_from_pool(pool_pid, state) do
      {:ok, snapshot} ->
        store_and_emit_snapshot(snapshot, reason, state)
        {:noreply, %{state | last_snapshot_at: now}}

      :error ->
        {:noreply, state}
    end
  end

  defp capture_snapshot_from_pool(nil, _state), do: :error

  defp capture_snapshot_from_pool(pool_pid, state) do
    case GenServer.call(
           EctoPoolInspector.StateTracker,
           {:capture_snapshot, pool_pid, state.config},
           10_000
         ) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _} -> :error
    end
  end

  defp store_and_emit_snapshot(snapshot, reason, state) do
    storage_pid = lookup_storage(state.repo)

    if storage_pid do
      GenServer.cast(storage_pid, {:store, Map.put(snapshot, :reason, reason)})
    end

    :telemetry.execute(
      [:ecto_pool_inspector, :snapshot, :captured],
      %{connection_count: length(snapshot.connections)},
      %{reason: reason, repo: state.repo}
    )
  end

  defp get_pool_pid_from_tracker(repo) do
    case GenServer.call(EctoPoolInspector.StateTracker, {:get_pool_pid, repo}) do
      {:ok, pool_pid} -> pool_pid
      {:error, :pool_not_discovered} -> nil
    end
  end

  defp should_trigger_queue_time?(queue_time_ns, triggers) do
    Enum.any?(triggers, fn
      {:queue_time, :p95, threshold_ms, :millisecond} ->
        queue_time_ms = System.convert_time_unit(queue_time_ns, :native, :millisecond)
        queue_time_ms > threshold_ms

      _ ->
        false
    end)
  end

  defp should_trigger_saturation?(saturation, triggers) do
    Enum.any?(triggers, fn
      {:pool_saturation, threshold} -> saturation >= threshold
      _ -> false
    end)
  end

  defp lookup_storage(repo) do
    case Registry.lookup(EctoPoolInspector.Registry, {repo, :storage}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
