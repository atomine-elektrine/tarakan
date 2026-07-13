defmodule Tarakan.Sync.MirrorRepository do
  @moduledoc """
  Mirrors one pinned commit of a hot repository over the git protocol.

  Enqueued when the code browser serves a commit that isn't mirrored yet, so
  storage follows the power law of what people actually view. The registered
  public identity is re-verified through the API immediately before fetching;
  anything that fails identity is discarded rather than retried.
  """

  use Oban.Worker,
    queue: :mirror,
    max_attempts: 5,
    unique: [period: 3600, states: :incomplete]

  alias Tarakan.GitHub
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryMirror

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repository_id" => repository_id, "commit_sha" => commit_sha}}) do
    with %Repository{host: "github.com"} = repository <- Repo.get(Repository, repository_id),
         false <- RepositoryMirror.has_commit?(repository.github_id, commit_sha),
         {:ok, _metadata} <- GitHub.verify_public_identity(repository) do
      case RepositoryMirror.mirror(repository, commit_sha) do
        {:ok, :mirrored} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # Already mirrored by a concurrent job.
      true ->
        :ok

      # Repository row gone, or its public identity no longer verifies:
      # nothing to mirror, and retrying will not change that.
      nil ->
        {:cancel, :repository_not_found}

      %Repository{} ->
        {:cancel, :unsupported_host}

      {:error, :identity_changed} ->
        RepositoryMirror.delete(mirror_github_id(repository_id))
        {:cancel, :identity_changed}

      {:error, :rate_limited} ->
        {:snooze, 300}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp mirror_github_id(repository_id) do
    case Repo.get(Repository, repository_id) do
      %Repository{github_id: github_id} when is_integer(github_id) -> github_id
      _other -> nil
    end
  end
end
