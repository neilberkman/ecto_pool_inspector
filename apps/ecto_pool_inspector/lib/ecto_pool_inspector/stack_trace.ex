defmodule EctoPoolInspector.StackTrace do
  @moduledoc """
  Captures and enriches stack traces for processes.
  """

  def capture(pid) when is_pid(pid) do
    case Process.info(pid, [:current_stacktrace, :initial_call, :current_function]) do
      nil ->
        {:error, :process_dead}

      info ->
        stack_trace = format_stack(info[:current_stacktrace] || [])
        context = identify_context(info[:current_stacktrace] || [], info[:initial_call])

        {:ok,
         %{
           context: context,
           current_function: inspect(info[:current_function]),
           initial_call: inspect(info[:initial_call]),
           stack_trace: stack_trace
         }}
    end
  catch
    _, _ ->
      {:error, :capture_failed}
  end

  defp format_stack([]), do: "No stack trace available"

  defp format_stack(stack) when is_list(stack) do
    Exception.format_stacktrace(stack)
  rescue
    _ -> inspect(stack)
  end

  defp format_stack(stack), do: inspect(stack)

  defp identify_context(stack, initial_call) do
    cond do
      phoenix_request?(stack) -> "Phoenix Request"
      oban_job?(initial_call) -> "Oban Job"
      broadway_processor?(stack) -> "Broadway Processor"
      genserver_call?(stack) -> "GenServer Call"
      task_async?(initial_call) -> "Task.async"
      true -> "Unknown"
    end
  end

  defp phoenix_request?(stack) do
    Enum.any?(stack, fn {mod, _fun, _arity, _location} ->
      elixir_module?(mod) and
        mod
        |> Module.split()
        |> List.first()
        |> Kernel.==("Phoenix")
    end)
  end

  defp oban_job?(nil), do: false

  defp oban_job?({mod, _, _}) when is_atom(mod) do
    elixir_module?(mod) and
      mod
      |> Module.split()
      |> List.first()
      |> Kernel.==("Oban")
  end

  defp oban_job?(_), do: false

  defp broadway_processor?(stack) do
    Enum.any?(stack, fn {mod, _fun, _arity, _location} ->
      elixir_module?(mod) and
        mod
        |> Module.split()
        |> List.first()
        |> Kernel.==("Broadway")
    end)
  end

  # Check if a module is an Elixir module (vs Erlang module)
  defp elixir_module?(mod) when is_atom(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> _ -> true
      _ -> false
    end
  end

  defp elixir_module?(_), do: false

  defp genserver_call?(stack) do
    Enum.any?(stack, fn
      {GenServer, :call, _, _} -> true
      _ -> false
    end)
  end

  defp task_async?({Task.Supervised, _, _}), do: true
  defp task_async?(_), do: false
end
