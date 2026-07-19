defmodule TarakanWeb.API.RepositoryController do
  @moduledoc """
  Discovery and registration of public repositories for scanning clients.

  `GET` lists reviewable repositories (`status=unscanned` for the work queue).
  `POST` registers a public GitHub repository by URL or `owner/name` so mass
  importers (awesome lists, OSINT harvests) can feed the registry.
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

  @doc """
  Registers a public GitHub repository.

  Body: `{"url": "owner/name"}` or `{"url": "https://github.com/owner/name"}`.
  Idempotent: an already-registered repository is returned as 200.
  """
  def create(conn, params) do
    url =
      params
      |> Map.get("url")
      |> Kernel.||(Map.get(params, "repository"))
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    if url == "" do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{url: ["is required"]}})
    else
      case Repositories.register_github_repository(url, conn.assigns.current_scope) do
        {:ok, repository} ->
          # Idempotent: 200 whether newly inserted or already present.
          json(conn, %{repository: repository_json(repository)})

        {:error, reason} ->
          registration_error(conn, reason)
      end
    end
  end

  defp registration_error(conn, :invalid_github_repository) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "url must be a public GitHub owner/name or repository URL"})
  end

  defp registration_error(conn, reason) when reason in [:not_found, :not_public] do
    conn
    |> put_status(:not_found)
    |> json(%{error: "repository was not found or is not public"})
  end

  defp registration_error(conn, :registration_limit) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "daily repository registration limit reached"})
  end

  defp registration_error(conn, reason) when reason in [:rate_limited, :request_limited] do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "too many registration requests; try again shortly"})
  end

  defp registration_error(conn, :unavailable) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "could not reach GitHub to verify the repository"})
  end

  defp registration_error(conn, :unauthorized) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "this credential cannot register repositories"})
  end

  defp registration_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "repository could not be registered"})
  end

  defp parse_limit(nil), do: 100

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> min(limit, 500)
      _other -> 100
    end
  end

  defp parse_limit(_), do: 100

  defp repository_json(repository) do
    status = Map.get(repository, :status) || repository.listing_status

    %{
      host: repository.host,
      owner: repository.owner,
      name: repository.name,
      status: status,
      listing_status: repository.listing_status,
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
