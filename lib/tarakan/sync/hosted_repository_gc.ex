defmodule Tarakan.Sync.HostedRepositoryGC do
  @moduledoc """
  Weekly maintenance for hosted repository storage.

  Runs `git gc --auto` in every hosted bare repository (automatic gc is
  disabled at init so pushes never pay for repacking) and refreshes the
  persisted disk size used for quota accounting.
  """

  use Oban.Worker,
    queue: :mirror,
    max_attempts: 3,
    unique: [period: 3600, states: :incomplete]

  import Ecto.Query, warn: false

  alias Tarakan.Git.Local
  alias Tarakan.HostedRepositories
  alias Tarakan.HostedRepositories.Storage
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository

  require Logger

  @gc_timeout_seconds 600

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    repositories =
      Repository
      |> where([repository], repository.host == ^Repository.hosted_host())
      |> Repo.all()

    Enum.each(repositories, &collect/1)
    :ok
  end

  defp collect(repository) do
    if Storage.exists?(repository) do
      dir = Storage.dir(repository)

      case Local.run(dir, ["-c", "gc.auto=6700", "gc", "--auto", "--quiet"],
             timeout_seconds: @gc_timeout_seconds
           ) do
        {:ok, _output} ->
          :ok

        {:error, reason} ->
          Logger.warning("gc failed for hosted repository #{repository.id}: #{inspect(reason)}")
      end

      _updated = HostedRepositories.update_disk_size(repository)
    end

    :ok
  end
end
