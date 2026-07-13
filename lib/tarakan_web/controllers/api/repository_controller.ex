defmodule TarakanWeb.API.RepositoryController do
  @moduledoc """
  Read-only discovery of the public review queue for scanning clients.

  Only publicly listed repositories are returned. `status=unscanned` yields the
  repositories with no disclosed verified review yet - the work a review client
  picks up.
  """
  use TarakanWeb, :controller

  alias Tarakan.Repositories

  def index(conn, params) do
    repositories =
      Repositories.list_reviewable_repositories(
        status: params["status"],
        limit: parse_limit(params["limit"])
      )

    json(conn, %{repositories: Enum.map(repositories, &repository_json/1)})
  end

  defp parse_limit(nil), do: 100

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> limit
      _other -> 100
    end
  end

  defp repository_json(repository) do
    %{
      host: repository.host,
      owner: repository.owner,
      name: repository.name,
      status: repository.status,
      default_branch: repository.default_branch,
      primary_language: repository.primary_language,
      scan_count: repository.scan_count,
      last_scanned_at: repository.last_scanned_at,
      registered_at: repository.inserted_at,
      record_url:
        TarakanWeb.Endpoint.url() <> TarakanWeb.RepositoryPaths.repository_path(repository)
    }
  end
end
