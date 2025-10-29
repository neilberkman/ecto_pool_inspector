defmodule EctoPoolInspector.StateTracker do
  @moduledoc """
  Singleton GenServer maintaining real-time connection state for ALL pools on the node.
  """

  use GenServer

  defstruct [
    # ETS table: {client_pid, pool_pid, checked_out_at, monitor_ref, depth}
    :state_table,
    # ETS table: {repo_atom, pool_pid}
    :mapping_table,
    # Optimized counters: %{pool_pid => count}
    :checkout_counts,
    # Config
    :cleanup_interval
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Create ETS tables
    state_table =
      :ets.new(:ecto_pool_inspector_state, [
        :public,
        :set,
        {:write_concurrency, true},
        {:read_concurrency, true}
      ])

    mapping_table =
      :ets.new(:ecto_pool_inspector_mapping, [
        :public,
        :set,
        {:read_concurrency, true}
      ])

    # Attach to telemetry events with unique names
    node_id = "#{node()}-#{System.system_time()}"

    :telemetry.attach(
      "ecto-pool-inspector-checkout-#{node_id}",
      [:db_connection, :connection, :checkout],
      &handle_checkout/4,
      self()
    )

    :telemetry.attach(
      "ecto-pool-inspector-checkin-#{node_id}",
      [:db_connection, :connection, :checkin],
      &handle_checkin/4,
      self()
    )

    # Schedule periodic cleanup
    cleanup_interval = opts[:cleanup_interval] || 60_000
    Process.send_after(self(), :cleanup_dead_entries, cleanup_interval)

    {:ok,
     %__MODULE__{
       checkout_counts: %{},
       cleanup_interval: cleanup_interval,
       mapping_table: mapping_table,
       state_table: state_table
     }}
  end

  # Telemetry handlers (called in telemetry process context)
  def handle_checkout(_event, _measurements, metadata, tracker_pid) do
    GenServer.cast(tracker_pid, {:checkout, metadata.pid, metadata.pool})
  end

  def handle_checkin(_event, _measurements, metadata, tracker_pid) do
    GenServer.cast(tracker_pid, {:checkin, metadata.pid})
  end

  @impl true
  def handle_cast({:discover_pool, repo, pool_pid}, state) do
    :ets.insert(state.mapping_table, {repo, pool_pid})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:checkout, client_pid, pool_pid}, state) do
    case :ets.lookup(state.state_table, client_pid) do
      [] ->
        # First checkout for this process
        monitor_ref = Process.monitor(client_pid)

        :ets.insert(state.state_table, {
          client_pid,
          pool_pid,
          System.monotonic_time(:millisecond),
          monitor_ref,
          # depth
          1
        })

        # Update counter cache
        new_counts = Map.update(state.checkout_counts, pool_pid, 1, &(&1 + 1))
        {:noreply, %{state | checkout_counts: new_counts}}

      [{^client_pid, pool_pid, checked_out_at, monitor_ref, depth}] ->
        # Nested transaction - update depth
        :ets.insert(
          state.state_table,
          {client_pid, pool_pid, checked_out_at, monitor_ref, depth + 1}
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:checkin, client_pid}, state) do
    case :ets.lookup(state.state_table, client_pid) do
      [{^client_pid, pool_pid, _checked_out_at, monitor_ref, depth}] ->
        if depth > 1 do
          # Still in nested transaction - just decrement depth
          :ets.update_element(state.state_table, client_pid, {5, depth - 1})
          {:noreply, state}
        else
          # Final checkin
          Process.demonitor(monitor_ref, [:flush])
          :ets.delete(state.state_table, client_pid)

          # Update counter cache
          new_counts = Map.update(state.checkout_counts, pool_pid, 0, &max(&1 - 1, 0))
          {:noreply, %{state | checkout_counts: new_counts}}
        end

      [] ->
        # Already cleaned up or not tracked
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Process died while holding connection
    case :ets.lookup(state.state_table, pid) do
      [{^pid, pool_pid, _checked_out_at, _monitor_ref, _depth}] ->
        :ets.delete(state.state_table, pid)

        # Update counter cache
        new_counts = Map.update(state.checkout_counts, pool_pid, 0, &max(&1 - 1, 0))
        {:noreply, %{state | checkout_counts: new_counts}}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup_dead_entries, state) do
    # Fallback cleanup for any missed :DOWN messages
    all_entries = :ets.tab2list(state.state_table)

    {dead_entries, new_counts} =
      Enum.reduce(all_entries, {[], state.checkout_counts}, fn
        {pid, pool_pid, _, _, _} = _entry, {dead_acc, counts_acc} ->
          if Process.alive?(pid) do
            {dead_acc, counts_acc}
          else
            # Clean up dead process and update counter
            updated_counts = Map.update(counts_acc, pool_pid, 0, &max(&1 - 1, 0))
            {[pid | dead_acc], updated_counts}
          end
      end)

    # Delete all dead entries
    Enum.each(dead_entries, &:ets.delete(state.state_table, &1))

    Process.send_after(self(), :cleanup_dead_entries, state.cleanup_interval)
    {:noreply, %{state | checkout_counts: new_counts}}
  end

  @impl true
  def handle_call({:get_pool_pid, repo}, _from, state) do
    result =
      case :ets.lookup(state.mapping_table, repo) do
        [{^repo, pool_pid}] -> {:ok, pool_pid}
        [] -> {:error, :pool_not_discovered}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_checkout_count, pool_pid}, _from, state) do
    # Use counter cache for O(1) performance
    count = Map.get(state.checkout_counts, pool_pid, 0)
    {:reply, count, state}
  end

  @impl true
  def handle_call({:capture_snapshot, pool_pid, config}, _from, state) do
    # Get all connections for this pool - simple filter since we use tuples now
    all_entries = :ets.tab2list(state.state_table)

    connections =
      Enum.filter(all_entries, fn
        {_pid, ^pool_pid, _checked_out_at, _monitor_ref, _depth} -> true
        _ -> false
      end)

    # Apply sampling configuration
    sampled_connections = sample_connections(connections, config)

    # Capture stack traces (using async for performance)
    snapshot_entries = capture_stack_traces(sampled_connections, config)

    snapshot = %{
      connections: snapshot_entries,
      node: node(),
      pool_pid: pool_pid,
      pool_size: config[:pool_size] || "unknown",
      sampled_connections: length(snapshot_entries),
      timestamp: DateTime.utc_now(),
      total_connections: length(connections)
    }

    {:reply, {:ok, snapshot}, state}
  end

  # Private helpers

  defp sample_connections(connections, config) do
    case config[:capture_stack_traces] do
      :none ->
        []

      :all ->
        connections

      :sample ->
        rate = config[:stack_trace_sample_rate] || 0.1
        Enum.filter(connections, fn _ -> :rand.uniform() <= rate end)
    end
  end

  defp capture_stack_traces(connections, config) do
    timeout = config[:stack_trace_timeout] || 100
    max_concurrency = config[:stack_trace_concurrency] || 10

    connections
    |> Task.async_stream(
      fn {pid, pool_pid, checked_out_at, _monitor_ref, depth} ->
        case EctoPoolInspector.StackTrace.capture(pid) do
          {:ok, stack_info} ->
            %{
              context: stack_info.context,
              depth: depth,
              held_for_ms: System.monotonic_time(:millisecond) - checked_out_at,
              initial_call: stack_info.initial_call,
              pid: pid,
              pool_pid: pool_pid,
              stack_trace: stack_info.stack_trace
            }

          {:error, _} ->
            %{
              context: "unknown",
              depth: depth,
              held_for_ms: System.monotonic_time(:millisecond) - checked_out_at,
              pid: pid,
              pool_pid: pool_pid,
              stack_trace: "unavailable"
            }
        end
      end,
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: max_concurrency
    )
    |> Enum.reduce([], fn
      {:ok, entry}, acc -> [entry | acc]
      {:exit, :timeout}, acc -> acc
      {:exit, _reason}, acc -> acc
    end)
  end
end
