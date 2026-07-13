defmodule TarakanWeb.SEOController do
  @moduledoc """
  Search-engine discovery endpoints.

  The sitemap enumerates only URLs whose content is already public: the
  registry home, listed repository security records, and the permalink of
  every finding from an accepted, fully disclosed review. Quarantined and
  summary-only material never appears here.
  """

  use TarakanWeb, :controller

  alias Tarakan.Repositories
  alias Tarakan.Scans
  alias TarakanWeb.RepositoryPaths

  # The sitemap protocol caps a single file at 50,000 URLs; the record must
  # move to a sitemap index before it grows past this.
  @max_urls 50_000

  def robots(conn, _params) do
    body = """
    User-agent: *
    Allow: /

    Sitemap: #{url(~p"/sitemap.xml")}
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  def sitemap(conn, _params) do
    base = TarakanWeb.Endpoint.url()

    repository_entries =
      Enum.map(Repositories.list_listed_repositories(), fn repository ->
        {RepositoryPaths.repository_security_path(repository), repository.updated_at}
      end)

    finding_entries =
      Enum.map(Scans.list_indexable_findings(), fn finding ->
        {~p"/findings/#{finding.public_id}", finding.updated_at}
      end)

    entries =
      [{"/", nil} | repository_entries ++ finding_entries]
      |> Enum.take(@max_urls)
      |> Enum.map(fn {path, lastmod} -> url_entry(base, path, lastmod) end)

    xml = [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">),
      entries,
      "</urlset>"
    ]

    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, xml)
  end

  defp url_entry(base, path, lastmod) do
    ["<url><loc>", xml_escape(base <> path), "</loc>", lastmod_element(lastmod), "</url>"]
  end

  defp lastmod_element(nil), do: []

  defp lastmod_element(%DateTime{} = datetime) do
    ["<lastmod>", datetime |> DateTime.to_date() |> Date.to_iso8601(), "</lastmod>"]
  end

  defp xml_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
