defmodule TarakanWeb.ExploreLive do
  use TarakanWeb, :live_view

  alias Tarakan.Activity
  alias Tarakan.Epidemics
  alias Tarakan.Reputation
  alias TarakanWeb.Presence

  @wire_limit 50
  # A search sweeps a wider slice of history than the visible window.
  @search_scan_limit 200
  @presence_topic "explore:observers"

  # Product language: Reports / Checks. Wire kinds stay :scan / :verdict internally.
  @kinds %{
    "all" => nil,
    "registrations" => :registration,
    "reports" => :scan,
    "checks" => :verdict,
    "comments" => :comment
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Activity.subscribe()
      Reputation.subscribe()
      Phoenix.PubSub.subscribe(Tarakan.PubSub, @presence_topic)
      {:ok, _ref} = Presence.track(self(), @presence_topic, socket.id, %{})
    end

    {:ok,
     socket
     |> assign(:page_title, "Explore")
     |> assign(
       :meta_description,
       "Public record: Reports, Checks, registrations, discussion."
     )
     |> assign(:canonical_path, ~p"/explore")
     |> assign(:kind, "all")
     |> assign(:query, "")
     |> assign(:watcher_count, watcher_count())
     |> assign(:hot_findings, Activity.hot_findings())
     |> assign(:epidemics, Epidemics.list_epidemics(min_repos: 2, days: 30, limit: 5))
     |> load_wire()}
  end

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) when is_map_key(@kinds, kind) do
    {:noreply, socket |> assign(:kind, kind) |> load_wire()}
  end

  def handle_event("search", params, socket) do
    query = params |> Map.get("q", "") |> String.trim()
    {:noreply, socket |> assign(:query, query) |> load_wire()}
  end

  @impl true
  def handle_info({:activity, entry}, socket) do
    if matches?(entry, socket.assigns.kind, socket.assigns.query) do
      {:noreply, stream_insert(socket, :wire, entry, at: 0, limit: @wire_limit)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:vote_changed, "canonical_finding", _id}, socket) do
    {:noreply, assign(socket, :hot_findings, Activity.hot_findings())}
  end

  def handle_info({:vote_changed, _subject_type, _id}, socket), do: {:noreply, socket}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :watcher_count, watcher_count())}
  end

  defp load_wire(socket) do
    %{kind: kind, query: query} = socket.assigns
    scan_limit = if query == "", do: @wire_limit, else: @search_scan_limit

    # Scope the kind in the query so a rare kind returns its own `scan_limit`
    # rows instead of being crowded out of the merged newest-N window.
    entries =
      scan_limit
      |> Activity.recent(verified_only: false, kind: Map.fetch!(@kinds, kind))
      |> Enum.filter(&matches_query?(&1, query))
      |> Enum.take(@wire_limit)

    stream(socket, :wire, entries, reset: true)
  end

  defp matches?(entry, kind, query) do
    matches_kind?(entry, kind) and matches_query?(entry, query)
  end

  defp matches_kind?(_entry, "all"), do: true
  defp matches_kind?(entry, kind), do: entry.kind == Map.fetch!(@kinds, kind)

  defp matches_query?(_entry, ""), do: true

  defp matches_query?(entry, query) do
    haystack =
      [
        Map.get(entry, :handle),
        Map.get(entry, :finding_title),
        entry.host,
        "#{entry.owner}/#{entry.name}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, String.downcase(query))
  end

  defp watcher_count do
    @presence_topic |> Presence.list() |> map_size()
  end

  # Reviews and verdicts live on the security tab; comments on the finding
  # page; a registration points at the repository itself.
  defp wire_entry_path(%{kind: :registration} = entry) do
    TarakanWeb.RepositoryPaths.repository_path(entry)
  end

  defp wire_entry_path(%{kind: :comment} = entry) do
    "/findings/#{entry.finding_public_id}"
  end

  defp wire_entry_path(entry) do
    TarakanWeb.RepositoryPaths.repository_security_path(entry)
  end

  defp ledger_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp filter_active?(current, value), do: current == value
end
