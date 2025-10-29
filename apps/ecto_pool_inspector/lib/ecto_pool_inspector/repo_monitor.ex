defmodule EctoPoolInspector.RepoMonitor do
  @moduledoc """
  Per-repo trigger evaluation with rate limiting.

  ## Pool Discovery

  The pool PID is discovered lazily via telemetry events. The first query to the repo
  will emit telemetry with `metadata.pool` which we use to register the pool.

  ## Important

  This means monitoring does not start until after the first query runs. Applications
  should run a throwaway query on startup if they want immediate monitoring.
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
    # Get pool size from repo config, fall back to inspector config
    pool_size = get_pool_size(repo, config)

    # Pool PID is discovered lazily via telemetry - see handle_query_event
    # No upfront discovery mechanism exists

    # Attach to repo query events
    attach_telemetry(repo, config)

    # Schedule saturation check
    poll_interval = config[:saturation_poll_interval] || 10_000
    Process.send_after(self(), :check_pool_saturation, poll_interval)

    {:ok,
     %__MODULE__{
       config: config,
       last_snapshot_at: nil,
       poll_interval: poll_interval,
       pool_pid: nil,
       pool_size: pool_size,
       repo: repo
     }}
  end

  # Telemetry handler (fast path)
  def handle_query_event(_event, measurements, metadata, {monitor_pid, config}) do
    # Discover pool PID from first query (if not already discovered)
    if metadata[:pool] do
      GenServer.cast(monitor_pid, {:discover_pool, metadata.pool})
    end

    # Check queue time trigger (NOT idle time - that's different)
    if measurements[:queue_time] do
      threshold_ns = get_queue_time_threshold_ns(config[:triggers] || [])

      if threshold_ns && measurements.queue_time > threshold_ns do
        GenServer.cast(monitor_pid, {:trigger_snapshot, :queue_time_exceeded})
      end
    end
  end

  @impl true
  def handle_cast({:discover_pool, pool_pid}, state) do
    if state.pool_pid == nil do
      # First time seeing this pool, register it
      GenServer.cast(EctoPoolInspector.StateTracker, {:discover_pool, state.repo, pool_pid})
      {:noreply, %{state | pool_pid: pool_pid}}
    else
      {:noreply, state}
    end
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

  @impl true
  def handle_info(:check_pool_saturation, state) do
    if state.pool_pid do
      count = GenServer.call(EctoPoolInspector.StateTracker, {:get_checkout_count, state.pool_pid})
      saturation = calculate_saturation(count, state.pool_size)

      if should_trigger_saturation?(saturation, state.config[:triggers] || []) do
        GenServer.cast(self(), {:trigger_snapshot, :pool_saturation})
      end
    end

    Process.send_after(self(), :check_pool_saturation, state.poll_interval)
    {:noreply, state}
  end

  # Private helpers

  defp get_pool_size(repo, config) do
    # Try repo config first (canonical source), fall back to inspector config
    case repo.config()[:pool_size] do
      nil -> config[:pool_size] || 10
      size when is_integer(size) -> size
      _ -> 10
    end
  end

  defp attach_telemetry(repo, config) do
    app_name = config[:app_name]

    if app_name do
      event_name = [app_name, :repo, :query]

      :telemetry.attach(
        "ecto-pool-inspector-monitor-#{repo}-#{node()}",
        event_name,
        &__MODULE__.handle_query_event/4,
        {self(), config}
      )
    end
  end

  defp get_queue_time_threshold_ns(triggers) do
    Enum.find_value(triggers, fn
      {:queue_time, threshold_ms} when is_integer(threshold_ms) ->
        System.convert_time_unit(threshold_ms, :millisecond, :native)

      _ ->
        nil
    end)
  end

  defp calculate_saturation(count, pool_size) when pool_size > 0 do
    min(count / pool_size, 1.0)
  end

  defp calculate_saturation(_count, _pool_size), do: 0.0

  defp should_capture_snapshot?(state, now) do
    min_interval = state.config[:snapshot_interval] || 60_000

    case state.last_snapshot_at do
      nil -> true
      last -> DateTime.diff(now, last, :millisecond) >= min_interval
    end
  end

  defp capture_and_store_snapshot(state, reason, now) do
    pool_pid = state.pool_pid

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
