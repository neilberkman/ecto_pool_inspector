defmodule EctoPoolInspector.RepoSupervisor do
  @moduledoc """
  Per-repo supervisor managing RepoMonitor and Storage for a single repo.
  """

  use Supervisor

  def start_link(repo_config) do
    repo = repo_config[:repo]
    Supervisor.start_link(__MODULE__, repo_config, name: :"#{__MODULE__}_#{inspect(repo)}")
  end

  @impl true
  def init(repo_config) do
    repo = repo_config[:repo]

    children = [
      {EctoPoolInspector.Storage.ETS, {repo, repo_config}},
      {EctoPoolInspector.RepoMonitor, {repo, repo_config}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
