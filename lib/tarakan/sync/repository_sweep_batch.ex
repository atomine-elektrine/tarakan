defmodule Tarakan.Sync.RepositorySweepBatch do
  @moduledoc """
  Syncs up to 100 repositories against one GraphQL `nodes(ids:)` lookup.

  Renames/transfers and metadata drift are adopted through
  `Repositories.adopt_canonical_identity/2` (identity stays keyed to the
  immutable id). Repositories that went private or disappeared get their
  code-browser cache evicted immediately instead of waiting for the next
  lazy view to fail closed.
  """

  use Oban.Worker, queue: :sync, max_attempts: 5

  import Ecto.Query, warn: false

  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryCode.Cache
  alias Tarakan.RepositoryMirror

  require Logger

  @drift_fields [
    :node_id,
    :owner,
    :name,
    :canonical_url,
    :default_branch,
    :description,
    :primary_language,
    :stars_count,
    :forks_count,
    :archived
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repository_ids" => repository_ids}})
      when is_list(repository_ids) do
    repositories =
      Repo.all(
        from repository in Repository,
          where: repository.id in ^repository_ids and not is_nil(repository.node_id)
      )

    case repositories do
      [] ->
        :ok

      repositories ->
        node_ids = Enum.map(repositories, & &1.node_id)

        case bulk_client().fetch_repositories_by_node_ids(node_ids) do
          {:ok, results} when length(results) == length(repositories) ->
            repositories
            |> Enum.zip(results)
            |> Enum.each(fn {repository, result} -> apply_result(repository, result) end)

            :ok

          {:ok, _mismatched} ->
            {:error, :invalid_response}

          {:error, :no_token} ->
            Logger.info("repository sweep skipped: no GITHUB_TOKEN configured")
            :ok

          {:error, :rate_limited} ->
            {:snooze, 900}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def perform(%Oban.Job{}), do: :ok

  defp apply_result(repository, nil) do
    Logger.warning(
      "repository #{repository.github_id} (#{repository.owner}/#{repository.name}) " <>
        "no longer resolves on the host; evicting cached code"
    )

    Cache.delete_repository(repository.github_id)
    RepositoryMirror.delete(repository.github_id)
  end

  defp apply_result(repository, :not_public) do
    Logger.warning(
      "repository #{repository.github_id} (#{repository.owner}/#{repository.name}) " <>
        "is no longer public; evicting cached code"
    )

    Cache.delete_repository(repository.github_id)
    RepositoryMirror.delete(repository.github_id)
  end

  defp apply_result(repository, %{github_id: github_id} = metadata)
       when github_id == repository.github_id do
    if drifted?(repository, metadata) do
      case Repositories.adopt_canonical_identity(repository, metadata) do
        {:ok, _updated} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "repository #{repository.github_id} sweep update failed: #{inspect(reason)}"
          )
      end
    else
      :ok
    end
  end

  defp apply_result(repository, _mismatched_identity) do
    Logger.warning(
      "repository #{repository.github_id} node id resolved to a different repository; " <>
        "evicting cached code"
    )

    Cache.delete_repository(repository.github_id)
    RepositoryMirror.delete(repository.github_id)
  end

  defp drifted?(repository, metadata) do
    Enum.any?(@drift_fields, fn field ->
      normalize(field, Map.get(metadata, field)) != Map.get(repository, field)
    end)
  end

  # Stored owner/name/host are lowercase; the host reports actual case.
  defp normalize(field, value) when field in [:owner, :name] and is_binary(value),
    do: String.downcase(value)

  defp normalize(_field, value), do: value

  defp bulk_client, do: Application.fetch_env!(:tarakan, :github_bulk_client)
end
