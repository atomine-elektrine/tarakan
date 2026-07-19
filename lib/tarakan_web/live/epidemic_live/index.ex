defmodule TarakanWeb.EpidemicLive.Index do
  @moduledoc "Cross-repo epidemic list: patterns spanning multiple listed repositories."
  use TarakanWeb, :live_view

  alias Tarakan.Epidemics

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Patterns")
     |> assign(
       :meta_description,
       "Cross-repo patterns: the same finding title in multiple listed repositories."
     )
     |> assign(:canonical_path, ~p"/patterns")
     |> assign(:days, 30)
     |> assign(:min_repos, 2)
     |> load_epidemics()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    days = parse_int(params["days"], socket.assigns.days, 1, 365)
    min_repos = parse_int(params["min_repos"], socket.assigns.min_repos, 2, 20)

    {:noreply,
     socket
     |> assign(:days, days)
     |> assign(:min_repos, min_repos)
     |> load_epidemics()}
  end

  defp load_epidemics(socket) do
    epidemics =
      Epidemics.list_epidemics(
        days: socket.assigns.days,
        min_repos: socket.assigns.min_repos,
        limit: 50
      )

    assign(socket, :epidemics, epidemics)
  end

  defp parse_int(value, default, min, max) do
    case Integer.parse(to_string(value || "")) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:wide}>
        <div class="flex flex-col gap-4 border-b-2 border-strong pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div class="max-w-2xl">
            <h1 class="font-display text-3xl font-medium uppercase tracking-[0.02em] text-ink sm:text-5xl">
              Patterns
            </h1>
            <p class="mt-3 text-sm leading-6 text-ink-muted">
              Same finding title in {@min_repos}+ listed repos within the window.
              Ranked by infected repo count.
            </p>
          </div>

          <form
            id="epidemics-filter"
            phx-change="filter"
            class="flex flex-wrap items-end gap-3 font-mono text-xs"
          >
            <label class="flex flex-col gap-1 text-ink-faint">
              Min repos
              <select
                name="min_repos"
                class="border-2 border-strong bg-panel px-2 py-1.5 text-ink"
              >
                <option :for={n <- [2, 3, 5, 10]} value={n} selected={@min_repos == n}>{n}</option>
              </select>
            </label>
            <label class="flex flex-col gap-1 text-ink-faint">
              Window
              <select name="days" class="border-2 border-strong bg-panel px-2 py-1.5 text-ink">
                <option :for={n <- [7, 30, 90, 365]} value={n} selected={@days == n}>
                  {n}d
                </option>
              </select>
            </label>
          </form>
        </div>

        <div
          :if={@epidemics == []}
          id="epidemics-empty"
          class="mt-10 border-2 border-strong bg-panel px-6 py-16 text-center"
        >
          <p class="text-sm font-medium text-ink">No multi-repo patterns in this window</p>
          <p class="mt-2 text-xs text-ink-muted">
            Patterns appear when the same finding title hits {@min_repos}+ listed repos.
          </p>
        </div>

        <div :if={@epidemics != []} class="mt-8">
          <.constellation id="epidemics-constellation" epidemics={@epidemics} />

          <ul id="epidemics-list" class="sr-only">
            <li :for={epidemic <- @epidemics} id={"epidemic-#{epidemic.pattern_key}"}>
              <.link navigate={~p"/patterns/#{epidemic.pattern_key}"}>
                {epidemic.title} · {epidemic.repo_count} repos
              </.link>
            </li>
          </ul>
        </div>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
