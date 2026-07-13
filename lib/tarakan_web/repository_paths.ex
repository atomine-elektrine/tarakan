defmodule TarakanWeb.RepositoryPaths do
  @moduledoc """
  Builds repository-scoped paths from a repository's stored host, so no view
  or controller hardcodes a single source host into its links.

  Remote repositories live under their host domain (`/github.com/owner/name`),
  so a source URL pastes directly onto Tarakan. Hosted repositories live at
  GitHub-style bare paths (`/handle/name`); `TarakanWeb.Plugs.HostedRoutes`
  maps that form onto the internal `/hosted` route scope.
  """

  use TarakanWeb, :verified_routes

  alias Tarakan.Repositories.Repository

  def repository_path(repository) do
    repository_root(repository)
  end

  def repository_security_path(repository) do
    repository_root(repository) <> "/security"
  end

  def repository_code_path(repository, commit_sha, path_segments \\ []) do
    root = repository_root(repository) <> "/code/" <> encode_path_segment(commit_sha)

    case path_segments do
      [] -> root
      segments -> root <> "/" <> Enum.map_join(segments, "/", &encode_path_segment/1)
    end
  end

  @doc """
  Clone URLs for a Tarakan-hosted repository, or nil for external hosts.

  The HTTPS URL derives from the endpoint's public URL; the SSH URL is
  included only while the SSH daemon is enabled.
  """
  def clone_urls(repository) do
    if Repository.hosted?(repository) do
      base = TarakanWeb.Endpoint.url()
      path = "#{repository.owner}/#{repository.name}.git"

      %{https: "#{base}/#{path}", ssh: ssh_clone_url(URI.parse(base).host, path)}
    end
  end

  defp ssh_clone_url(host, path) do
    config = Application.get_env(:tarakan, Tarakan.GitSSH, [])

    if Keyword.get(config, :enabled, false) do
      case Keyword.get(config, :port, 22) do
        22 -> "ssh://git@#{host}/#{path}"
        port -> "ssh://git@#{host}:#{port}/#{path}"
      end
    end
  end

  defp repository_root(%{owner: owner, name: name} = repository) do
    if Repository.hosted?(repository) do
      "/" <> encode_path_segment(owner) <> "/" <> encode_path_segment(name)
    else
      "/" <>
        encode_path_segment(repository.host) <>
        "/" <> encode_path_segment(owner) <> "/" <> encode_path_segment(name)
    end
  end

  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
