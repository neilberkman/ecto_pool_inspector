defmodule EctoPoolInspector.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Delegate to the main EctoPoolInspector supervisor
    EctoPoolInspector.start_link([])
  end
end
