defmodule TarakanWeb.SEOController do
  @moduledoc """
  Search-engine discovery endpoints.

  Streams listed repos and findings via cursors. Single-file sitemap stays
  under 50k URLs; multi-file index kicks in at 20k listed repositories.
  """

  use TarakanWeb, :controller

  alias Tarakan.Repositories
  alias Tarakan.Scans
  alias Tarakan.Work
  alias TarakanWeb.RepositoryPaths

  @max_urls 50_000
  @multi_file_listed_threshold 20_000
  @child_page_size 10_000

  def robots(conn, _params) do
    body = """
    User-agent: *
    Allow: /

    Disallow: /*/code/
    Disallow: /findings/*/code

    Sitemap: #{url(~p"/sitemap.xml")}
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  def sitemap(conn, _params) do
    listed = Repositories.registry_stats().repositories || 0

    if listed >= @multi_file_listed_threshold do
      sitemap_index(conn)
    else
      sitemap_single(conn)
    end
  end

  def sitemap_hubs(conn, _params) do
    base = TarakanWeb.Endpoint.url()
    now = DateTime.utc_now()

    entries =
      hub_entries(now)
      |> Enum.map(fn {path, lastmod, priority} -> url_entry(base, path, lastmod, priority) end)

    send_urlset(conn, entries)
  end

  def sitemap_repos(conn, %{"page" => page}) do
    page = parse_page(page)
    base = TarakanWeb.Endpoint.url()
    offset = (page - 1) * @child_page_size

    {entries, _} =
      Repositories.stream_listed_repositories(limit: 1_000)
      |> Enum.reduce_while({[], 0}, fn repo, {acc, i} ->
        cond do
          i < offset ->
            {:cont, {acc, i + 1}}

          length(acc) >= @child_page_size ->
            {:halt, {acc, i}}

          true ->
            entry =
              {RepositoryPaths.repository_security_path(repo), repo.updated_at, "0.8"}

            {:cont, {[entry | acc], i + 1}}
        end
      end)

    xml_entries =
      entries
      |> Enum.reverse()
      |> Enum.map(fn {path, lastmod, priority} -> url_entry(base, path, lastmod, priority) end)

    send_urlset(conn, xml_entries)
  end

  def sitemap_findings(conn, %{"page" => page}) do
    page = parse_page(page)
    base = TarakanWeb.Endpoint.url()
    offset = (page - 1) * @child_page_size

    {entries, _} =
      Scans.stream_indexable_findings()
      |> Enum.reduce_while({[], 0}, fn finding, {acc, i} ->
        cond do
          i < offset ->
            {:cont, {acc, i + 1}}

          length(acc) >= @child_page_size ->
            {:halt, {acc, i}}

          true ->
            priority =
              cond do
                Map.get(finding, :verified) == true -> "0.85"
                (Map.get(finding, :confirmations_count) || 0) > 0 -> "0.75"
                true -> "0.65"
              end

            entry = {~p"/findings/#{finding.public_id}", finding.updated_at, priority}
            {:cont, {[entry | acc], i + 1}}
        end
      end)

    xml_entries =
      entries
      |> Enum.reverse()
      |> Enum.map(fn {path, lastmod, priority} -> url_entry(base, path, lastmod, priority) end)

    send_urlset(conn, xml_entries)
  end

  def sitemap_jobs(conn, %{"page" => page}) do
    page = parse_page(page)
    base = TarakanWeb.Endpoint.url()

    entries =
      Work.list_indexable_public_tasks()
      |> Enum.drop((page - 1) * @child_page_size)
      |> Enum.take(@child_page_size)
      |> Enum.map(fn task ->
        priority = if task.kind == "verify_findings", do: "0.8", else: "0.7"
        url_entry(base, ~p"/jobs/#{task.id}", task.updated_at, priority)
      end)

    send_urlset(conn, entries)
  end

  defp sitemap_index(conn) do
    base = TarakanWeb.Endpoint.url()
    listed = Repositories.registry_stats().repositories || 0
    repo_pages = max(ceil(listed / @child_page_size), 1)
    # Findings unknown without full count; emit a few pages (crawlers stop on empty).
    finding_pages = 5
    job_pages = 1

    locs =
      ["#{base}/sitemap/hubs.xml"] ++
        Enum.map(1..repo_pages, &"#{base}/sitemap/repos/#{&1}") ++
        Enum.map(1..finding_pages, &"#{base}/sitemap/findings/#{&1}") ++
        Enum.map(1..job_pages, &"#{base}/sitemap/jobs/#{&1}")

    body = [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">),
      Enum.map(locs, fn loc ->
        ["<sitemap><loc>", xml_escape(loc), "</loc></sitemap>"]
      end),
      "</sitemapindex>"
    ]

    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, body)
  end

  defp sitemap_single(conn) do
    base = TarakanWeb.Endpoint.url()
    now = DateTime.utc_now()

    hub_entries = hub_entries(now)

    repository_entries =
      Repositories.stream_listed_repositories()
      |> Enum.map(fn repository ->
        {RepositoryPaths.repository_security_path(repository), repository.updated_at, "0.8"}
      end)

    finding_entries =
      Scans.stream_indexable_findings()
      |> Enum.map(fn finding ->
        priority =
          cond do
            Map.get(finding, :verified) == true -> "0.85"
            (Map.get(finding, :confirmations_count) || 0) > 0 -> "0.75"
            true -> "0.65"
          end

        {~p"/findings/#{finding.public_id}", finding.updated_at, priority}
      end)

    job_entries =
      Enum.map(Work.list_indexable_public_tasks(), fn task ->
        priority = if task.kind == "verify_findings", do: "0.8", else: "0.7"
        {~p"/jobs/#{task.id}", task.updated_at, priority}
      end)

    entries =
      (hub_entries ++ finding_entries ++ job_entries ++ repository_entries)
      |> Enum.take(@max_urls)
      |> Enum.map(fn
        {path, lastmod, priority} -> url_entry(base, path, lastmod, priority)
        {path, lastmod} -> url_entry(base, path, lastmod, "0.5")
      end)

    send_urlset(conn, entries)
  end

  defp hub_entries(now) do
    [
      {"/explore", now, "1.0"},
      {"/", now, "0.9"},
      {"/jobs", now, "0.9"},
      {"/agents", now, "0.9"},
      {"/patterns", now, "0.85"},
      {"/leaderboard", now, "0.7"}
    ]
  end

  defp send_urlset(conn, entries) do
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

  defp parse_page(page) do
    case Integer.parse(to_string(page)) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp url_entry(base, path, lastmod, priority) do
    [
      "<url><loc>",
      xml_escape(base <> path),
      "</loc>",
      lastmod_element(lastmod),
      "<priority>",
      priority,
      "</priority>",
      "</url>"
    ]
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
