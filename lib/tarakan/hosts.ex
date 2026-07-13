defmodule Tarakan.Hosts do
  @moduledoc """
  Registry of source-code hosts Tarakan can reference.

  Remote repositories use the canonical host domain as their first URL
  segment, so a source URL pastes directly onto Tarakan:
  `github.com/rails/rails` → `/github.com/rails/rails`. The short legacy
  slugs (`/github/...`, `/tarakan/...`) still resolve so old links and API
  clients keep working. Tarakan-hosted repositories don't use a host
  segment at all - they live at `/~handle/name`.

  Hosts stay disabled until a connector exists, so their routes 404 instead
  of half-working.
  """

  @hosts [
    %{legacy_slug: "tarakan", host: "tarakan.lol", display: "Tarakan", enabled: true},
    %{legacy_slug: "github", host: "github.com", display: "GitHub", enabled: true},
    %{legacy_slug: "gitlab", host: "gitlab.com", display: "GitLab", enabled: false},
    %{legacy_slug: "codeberg", host: "codeberg.org", display: "Codeberg", enabled: false},
    %{legacy_slug: "bitbucket", host: "bitbucket.org", display: "Bitbucket", enabled: false}
  ]

  @doc """
  Resolves a URL segment to a canonical host name.

  Accepts the host domain itself (`github.com`) and the legacy short slug
  (`github`). Disabled hosts do not resolve.
  """
  def host_for_slug(slug) when is_binary(slug) do
    case Enum.find(@hosts, &(&1.enabled and (&1.host == slug or &1.legacy_slug == slug))) do
      %{host: host} -> {:ok, host}
      nil -> :error
    end
  end

  def host_for_slug(_slug), do: :error

  @doc """
  Whether a URL segment denotes a source host rather than an account handle.

  Host domains always contain a dot and legacy slugs resolve through the
  registry; account handles can be neither (dots are rejected at
  registration and slug words are reserved handles).
  """
  def host_segment?(segment) when is_binary(segment) do
    String.contains?(segment, ".") or match?({:ok, _host}, host_for_slug(segment))
  end

  @doc "Display name for a canonical host, e.g. \"GitHub\"."
  def display_name(host) do
    case Enum.find(@hosts, &(&1.host == host)) do
      %{display: display} -> display
      nil -> host
    end
  end
end
