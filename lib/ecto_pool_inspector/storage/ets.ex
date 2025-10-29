defmodule EctoPoolInspector.Storage.ETS do
  @moduledoc """
  Node-local circular buffer for snapshot storage using ETS.
  """

  use GenServer

  defstruct [:max_snapshots, :repo, :table]

  def start_link({repo, config}) do
    GenServer.start_link(__MODULE__, {repo, config})
  end

  @impl true
  def init({repo, config}) do
    # Create unique ETS table
    table_name = :"ecto_pool_inspector_storage_#{inspect(repo)}_#{node()}"
    table = :ets.new(table_name, [:ordered_set, :public])

    # Register with Registry
    Registry.register(EctoPoolInspector.Registry, {repo, :storage}, self())

    {:ok,
     %__MODULE__{
       max_snapshots: config[:max_snapshots] || 50,
       repo: repo,
       table: table
     }}
  end

  @impl true
  def handle_cast({:store, snapshot}, state) do
    # Use timestamp as key for ordering
    key = {DateTime.to_unix(snapshot.timestamp, :microsecond), :rand.uniform()}
    :ets.insert(state.table, {key, snapshot})

    # Enforce circular buffer
    size = :ets.info(state.table, :size)

    if size > state.max_snapshots do
      oldest_key = :ets.first(state.table)
      :ets.delete(state.table, oldest_key)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:latest_snapshot, _from, state) do
    result =
      case :ets.last(state.table) do
        :"$end_of_table" ->
          nil

        key ->
          case :ets.lookup(state.table, key) do
            [{^key, snapshot}] -> snapshot
            [] -> nil
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    limit = opts[:limit] || 10

    # Get most recent snapshots
    snapshots =
      :ets.tab2list(state.table)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))

    {:reply, snapshots, state}
  end

  @impl true
  def handle_call({:capture, reason}, _from, state) do
    with {:ok, pool_pid} <- get_pool_pid(state.repo),
         config = Application.get_env(:ecto_pool_inspector, state.repo, []),
         {:ok, snapshot} <- capture_snapshot(pool_pid, config) do
      snapshot_with_reason = Map.put(snapshot, :reason, reason)
      store_snapshot(state, snapshot_with_reason)
      {:reply, {:ok, snapshot_with_reason}, state}
    else
      error -> {:reply, error, state}
    end
  end

  defp get_pool_pid(repo) do
    GenServer.call(EctoPoolInspector.StateTracker, {:get_pool_pid, repo})
  end

  defp capture_snapshot(pool_pid, config) do
    GenServer.call(EctoPoolInspector.StateTracker, {:capture_snapshot, pool_pid, config}, 10_000)
  end

  defp store_snapshot(state, snapshot) do
    key = {DateTime.to_unix(snapshot.timestamp, :microsecond), :rand.uniform()}
    :ets.insert(state.table, {key, snapshot})
    enforce_circular_buffer(state)
  end

  defp enforce_circular_buffer(state) do
    size = :ets.info(state.table, :size)

    if size > state.max_snapshots do
      oldest_key = :ets.first(state.table)
      :ets.delete(state.table, oldest_key)
    end
  end
end
