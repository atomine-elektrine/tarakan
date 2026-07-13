defmodule Tarakan.HostedRepositories.PostReceive do
  @moduledoc """
  Bookkeeping after a successful push, in place of git hooks.

  Hosted repositories never execute hook scripts; this module is invoked by
  the transport layer after `git receive-pack` exits successfully. It is
  best-effort: the push has already succeeded at the git level, so failures
  here are logged and never surfaced to the client.
  """

  alias Tarakan.Audit
  alias Tarakan.Git.Local
  alias Tarakan.HostedRepositories
  alias Tarakan.HostedRepositories.Storage
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryCode.Cache

  require Logger

  def run(%Repository{} = repository, scope) do
    repository = Repo.get(Repository, repository.id)

    if repository && HostedRepositories.hosted?(repository) do
      dir = Storage.dir(repository)

      repository
      |> settle_head(dir)
      |> record_push(dir)

      Cache.delete_hosted(repository.id)
      audit_push(repository, scope)
    end

    :ok
  rescue
    error ->
      Logger.warning("post-receive bookkeeping failed: #{Exception.message(error)}")
      :ok
  end

  # A fresh repository's HEAD may point at a branch that was never pushed
  # (e.g. HEAD -> master while the client pushed main). When exactly one
  # branch exists, adopt it so clones and the browser have a default.
  defp settle_head(repository, dir) do
    case Local.head_commit(dir) do
      {:ok, %{branch: branch}} ->
        persist_default_branch(repository, branch)

      :empty ->
        case Local.branches(dir) do
          {:ok, [only_branch]} ->
            _ = Local.run(dir, ["symbolic-ref", "HEAD", "refs/heads/#{only_branch}"])
            persist_default_branch(repository, only_branch)

          _other ->
            repository
        end

      :miss ->
        repository
    end
  end

  defp persist_default_branch(%Repository{default_branch: branch} = repository, branch),
    do: repository

  defp persist_default_branch(repository, branch) do
    repository
    |> Ecto.Changeset.change(default_branch: branch)
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, _changeset} -> repository
    end
  end

  defp record_push(repository, _dir) do
    disk_size =
      case Storage.disk_size_bytes(repository) do
        {:ok, bytes} -> bytes
        _error -> repository.disk_size_bytes
      end

    repository
    |> Ecto.Changeset.change(
      pushed_at: DateTime.utc_now(:microsecond),
      disk_size_bytes: disk_size
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, _changeset} -> repository
    end
  end

  defp audit_push(repository, scope) do
    case Audit.record(scope, :repository_pushed, repository, %{}) do
      {:ok, _event} -> :ok
      {:error, reason} -> Logger.warning("push audit failed: #{inspect(reason)}")
    end
  end
end
