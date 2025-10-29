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
    table_name = :"ecto_pool_inspector_storage_#{inspect(repo)}_#{node()}"
    table = :ets.new(table_name, [:ordered_set, :public])

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
    # Use microsecond timestamp + random integer (1..1M) to avoid collisions
    key = {DateTime.to_unix(snapshot.timestamp, :microsecond), :rand.uniform(1_000_000)}
    :ets.insert(state.table, {key, snapshot})
    enforce_circular_buffer(state)
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
         config = get_config(state.repo),
         {:ok, snapshot} <- capture_snapshot(pool_pid, config) do
      snapshot_with_reason = Map.put(snapshot, :reason, reason)
      store_snapshot_direct(state, snapshot_with_reason)
      {:reply, {:ok, snapshot_with_reason}, state}
    else
      error -> {:reply, error, state}
    end
  end

  # Private helpers

  defp get_pool_pid(repo) do
    GenServer.call(EctoPoolInspector.StateTracker, {:get_pool_pid, repo}, 5_000)
  end

  defp get_config(repo) do
    Application.get_env(:ecto_pool_inspector, repo, [])
  end

  defp capture_snapshot(pool_pid, config) do
    GenServer.call(EctoPoolInspector.StateTracker, {:capture_snapshot, pool_pid, config}, 15_000)
  end

  defp store_snapshot_direct(state, snapshot) do
    key = {DateTime.to_unix(snapshot.timestamp, :microsecond), :rand.uniform(1_000_000)}
    :ets.insert(state.table, {key, snapshot})
    enforce_circular_buffer(state)
  end

  defp enforce_circular_buffer(state) do
    size = :ets.info(state.table, :size)
    excess = size - state.max_snapshots

    if excess > 0 do
      # Delete multiple entries if we're over the limit
      # This handles concurrent inserts better
      delete_oldest_n(state.table, excess)
    end
  end

  defp delete_oldest_n(_table, 0), do: :ok

  defp delete_oldest_n(table, n) when n > 0 do
    case :ets.first(table) do
      :"$end_of_table" ->
        :ok

      key ->
        :ets.delete(table, key)
        delete_oldest_n(table, n - 1)
    end
  end
end
