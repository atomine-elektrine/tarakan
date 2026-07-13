defmodule TarakanWeb.LeaderboardLive do
  use TarakanWeb, :live_view

  alias Tarakan.Leaderboard

  @sorts %{
    "reputation" => :reputation,
    "reviews" => :reviews,
    "findings" => :findings,
    "verdicts" => :verdicts
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Leaderboard")
     |> assign(
       :meta_description,
       "Top contributors to Tarakan, the public security record for open source."
     )
     |> assign(:sort, "reputation")
     |> load_entries()}
  end

  @impl true
  def handle_event("sort", %{"by" => by}, socket) when is_map_key(@sorts, by) do
    {:noreply, socket |> assign(:sort, by) |> load_entries()}
  end

  defp load_entries(socket) do
    assign(socket, :entries, Leaderboard.top(Map.fetch!(@sorts, socket.assigns.sort)))
  end

  @doc false
  def tier_label("reviewer"), do: "Reviewer"
  def tier_label("contributor"), do: "Contributor"
  def tier_label(_new), do: "New"

  @doc false
  def rank_style(1), do: "text-signal"
  def rank_style(2), do: "text-ink"
  def rank_style(3), do: "text-ink-muted"
  def rank_style(_), do: "text-ink-faint"
end
