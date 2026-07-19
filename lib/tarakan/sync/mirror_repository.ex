defmodule Tarakan.Sync.MirrorRepository do
  @moduledoc """
  Mirrors one pinned commit over the git protocol (not the GitHub REST API).

  Enqueued when a commit is first needed or on registration. No API identity
  check: `git fetch` of a public HTTPS remote is the source of truth; private
  or missing repos fail the fetch and cancel.
  """

  use Oban.Worker,
    queue: :mirror,
    max_attempts: 5,
    unique: [period: 3600, states: :incomplete]

  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryMirror

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repository_id" => repository_id, "commit_sha" => commit_sha}}) do
    with %Repository{host: "github.com"} = repository <- Repo.get(Repository, repository_id),
         false <- RepositoryMirror.has_commit?(repository.github_id, commit_sha) do
      case RepositoryMirror.mirror(repository, commit_sha) do
        {:ok, :mirrored} -> :ok
        {:error, :fetch_failed} -> {:snooze, 120}
        {:error, reason} -> {:error, reason}
      end
    else
      true ->
        :ok

      nil ->
        {:cancel, :repository_not_found}

      %Repository{} ->
        {:cancel, :unsupported_host}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"repository_id" => repository_id, "ref" => ref}})
      when is_binary(ref) do
    case Repo.get(Repository, repository_id) do
      %Repository{host: "github.com"} = repository ->
        with {:ok, sha} <- RepositoryMirror.ls_remote_sha(repository, ref),
             :ok <- RepositoryMirror.ensure_commit(repository, sha) do
          :ok
        else
          {:error, :fetch_failed} -> {:snooze, 120}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:cancel, :repository_not_found}

      %Repository{} ->
        {:cancel, :unsupported_host}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}
end
