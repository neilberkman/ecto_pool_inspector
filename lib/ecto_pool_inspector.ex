defmodule EctoPoolInspector do
  @moduledoc """
  Main API for inspecting Ecto connection pools across the cluster.

  EctoPoolInspector provides real-time visibility into Ecto connection pool usage
  in production Elixir applications. When database connection pools become exhausted,
  this library captures point-in-time snapshots showing which processes hold connections,
  their stack traces, hold durations, and application context.

  ## Configuration

  Configure in your `config/config.exs` or `config/runtime.exs`:

      config :ecto_pool_inspector,
        repos: [
          %{
            repo: MyApp.Repo,
            app_name: :my_app,
            triggers: [
              {:pool_saturation, 0.8},
              {:queue_time, :p95, 200, :millisecond}
            ],
            capture_stack_traces: :sample,
            stack_trace_sample_rate: 0.1,
            max_snapshots: 50,
            pool_size: 10
          }
        ]

  Add to your application supervision tree:

      def start(_type, _args) do
        children = [
          MyApp.Repo,
          {EctoPoolInspector, []},
          # ... other children
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## Usage

      # Manual snapshot capture
      EctoPoolInspector.capture_snapshot(MyApp.Repo, :all, :manual_debug)

      # Get latest snapshot from all nodes
      EctoPoolInspector.latest_snapshot(MyApp.Repo, :all)
      |> EctoPoolInspector.format_snapshot()

      # List recent snapshots
      EctoPoolInspector.list_snapshots(MyApp.Repo, :all, limit: 5)
  """

  use Supervisor

  @doc """
  Starts the inspector supervisor for configured repos.

  Called from your application.ex:

      children = [
        {EctoPoolInspector, []}
      ]
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Get configured repos
    repos = Application.get_env(:ecto_pool_inspector, :repos, [])

    # Start a RepoSupervisor for each configured repo
    children =
      [
        # Start the Registry first
        {Registry, keys: :unique, name: EctoPoolInspector.Registry},
        # Start the singleton StateTracker
        {EctoPoolInspector.StateTracker, []}
      ] ++
        Enum.map(repos, fn repo_config ->
          {EctoPoolInspector.RepoSupervisor, repo_config}
        end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Manually captures a snapshot.

  ## Options

    * `:node_spec` - `:all` | `:local` | `node()` | `[node()]`
    * `:reason` - Atom describing why snapshot was captured

  ## Returns

    * For `:local` - Single snapshot
    * For `:all` or list - `%{node => snapshot_or_error}`

  ## Examples

      # Capture on all nodes
      EctoPoolInspector.capture_snapshot(MyApp.Repo, :all, :manual_debug)

      # Capture on local node only
      EctoPoolInspector.capture_snapshot(MyApp.Repo, :local, :investigating_timeout)

      # Capture on specific nodes
      EctoPoolInspector.capture_snapshot(MyApp.Repo, [node()], :test)
  """
  def capture_snapshot(repo, node_spec \\ :all, reason \\ :manual) do
    case node_spec do
      :local ->
        __local_capture_snapshot__(repo, reason)

      :all ->
        nodes = [node() | Node.list()]
        capture_from_nodes(repo, nodes, reason)

      node when is_atom(node) ->
        capture_from_nodes(repo, [node], reason)

      nodes when is_list(nodes) ->
        capture_from_nodes(repo, nodes, reason)
    end
  end

  @doc """
  Retrieves the most recent snapshot.

  ## Examples

      # Latest from all nodes
      EctoPoolInspector.latest_snapshot(MyApp.Repo, :all)

      # Latest from local node
      EctoPoolInspector.latest_snapshot(MyApp.Repo, :local)
  """
  def latest_snapshot(repo, node_spec \\ :all) do
    case node_spec do
      :local ->
        __local_latest_snapshot__(repo)

      :all ->
        nodes = [node() | Node.list()]
        latest_from_nodes(repo, nodes)

      node when is_atom(node) ->
        latest_from_nodes(repo, [node])

      nodes when is_list(nodes) ->
        latest_from_nodes(repo, nodes)
    end
  end

  @doc """
  Lists stored snapshots with optional filtering.

  ## Options

    * `:limit` - Maximum number of snapshots to return (default: 10)

  ## Examples

      # List recent snapshots from all nodes
      EctoPoolInspector.list_snapshots(MyApp.Repo, :all, limit: 5)
  """
  def list_snapshots(repo, node_spec \\ :all, opts \\ []) do
    case node_spec do
      :local ->
        __local_list_snapshots__(repo, opts)

      :all ->
        nodes = [node() | Node.list()]
        list_from_nodes(repo, nodes, opts)

      node when is_atom(node) ->
        list_from_nodes(repo, [node], opts)

      nodes when is_list(nodes) ->
        list_from_nodes(repo, nodes, opts)
    end
  end

  @doc """
  Pretty-prints snapshots for IEx inspection.

  ## Examples

      EctoPoolInspector.latest_snapshot(MyApp.Repo)
      |> EctoPoolInspector.format_snapshot()
  """
  def format_snapshot(snapshot_or_map) do
    case snapshot_or_map do
      %{} = map when not is_struct(map) ->
        # Multi-node result
        Enum.each(map, fn {node, result} ->
          IO.puts("\n=== Node: #{node} ===")
          format_single_snapshot(result)
        end)

      snapshot ->
        format_single_snapshot(snapshot)
    end
  end

  # Internal RPC handlers (not part of public API)

  @doc false
  def __local_capture_snapshot__(repo, reason) do
    case lookup_storage(repo) do
      nil ->
        {:error, :storage_not_found}

      storage_pid ->
        GenServer.call(storage_pid, {:capture, reason}, 15_000)
    end
  end

  @doc false
  def __local_latest_snapshot__(repo) do
    case lookup_storage(repo) do
      nil -> {:error, :storage_not_found}
      storage_pid -> GenServer.call(storage_pid, :latest_snapshot)
    end
  end

  @doc false
  def __local_list_snapshots__(repo, opts) do
    case lookup_storage(repo) do
      nil -> {:error, :storage_not_found}
      storage_pid -> GenServer.call(storage_pid, {:list, opts})
    end
  end

  # Private helpers

  defp capture_from_nodes(repo, nodes, reason) do
    timeout = Application.get_env(:ecto_pool_inspector, :node_multicall_timeout, 5_000)

    results =
      Enum.map(nodes, fn node ->
        task =
          Task.async(fn ->
            try do
              :rpc.call(node, __MODULE__, :__local_capture_snapshot__, [repo, reason], timeout)
            catch
              :exit, reason -> {:badrpc, reason}
            end
          end)

        {node, task}
      end)

    Map.new(results, fn {node, task} ->
      result =
        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, {:badrpc, reason}} -> {:error, {:rpc_failed, reason}}
          {:ok, result} -> result
          nil -> {:error, :timeout}
        end

      {node, result}
    end)
  end

  defp latest_from_nodes(repo, nodes) do
    timeout = Application.get_env(:ecto_pool_inspector, :node_multicall_timeout, 5_000)

    results =
      Enum.map(nodes, fn node ->
        task =
          Task.async(fn ->
            try do
              :rpc.call(node, __MODULE__, :__local_latest_snapshot__, [repo], timeout)
            catch
              :exit, reason -> {:badrpc, reason}
            end
          end)

        {node, task}
      end)

    Map.new(results, fn {node, task} ->
      result =
        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, {:badrpc, reason}} -> {:error, {:rpc_failed, reason}}
          {:ok, result} -> result
          nil -> {:error, :timeout}
        end

      {node, result}
    end)
  end

  defp list_from_nodes(repo, nodes, opts) do
    timeout = Application.get_env(:ecto_pool_inspector, :node_multicall_timeout, 5_000)

    results =
      Enum.map(nodes, fn node ->
        task =
          Task.async(fn ->
            try do
              :rpc.call(node, __MODULE__, :__local_list_snapshots__, [repo, opts], timeout)
            catch
              :exit, reason -> {:badrpc, reason}
            end
          end)

        {node, task}
      end)

    Map.new(results, fn {node, task} ->
      result =
        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, {:badrpc, reason}} -> {:error, {:rpc_failed, reason}}
          {:ok, result} -> result
          nil -> {:error, :timeout}
        end

      {node, result}
    end)
  end

  defp lookup_storage(repo) do
    case Registry.lookup(EctoPoolInspector.Registry, {repo, :storage}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp format_single_snapshot({:error, reason}) do
    IO.puts("Error: #{inspect(reason)}")
  end

  defp format_single_snapshot(nil) do
    IO.puts("No snapshots available")
  end

  defp format_single_snapshot(snapshot) do
    IO.puts("""
    Snapshot at #{snapshot.timestamp}
    Node: #{snapshot.node}
    Reason: #{snapshot[:reason] || "unknown"}
    Pool Size: #{snapshot.pool_size}
    Total Connections: #{snapshot.total_connections}
    Sampled Connections: #{snapshot.sampled_connections}
    """)

    if snapshot.sampled_connections > 0 do
      IO.puts("\nConnection Details:")

      Enum.each(snapshot.connections, fn conn ->
        IO.puts("""

        PID: #{inspect(conn.pid)}
        Held For: #{conn.held_for_ms}ms
        Depth: #{conn.depth}
        Context: #{conn.context}
        Initial Call: #{conn.initial_call}

        Stack Trace:
        #{conn.stack_trace}
        """)
      end)
    end
  end
end
