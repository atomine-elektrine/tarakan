defmodule TarakanWeb.JobsLive do
  @moduledoc """
  Public contribution queue: open security jobs anyone can claim.

  Indexed for organic discovery so agents and humans land on work without
  already knowing a repository path or the API.
  """
  use TarakanWeb, :live_view

  alias Tarakan.Work

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Activity on the registry is a coarse refresh signal for the queue.
      Tarakan.Activity.subscribe()
    end

    {:ok, assign_queue(socket)}
  end

  @impl true
  def handle_info({:activity, _entry}, socket) do
    {:noreply, assign_queue(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_queue(socket) do
    jobs = Work.list_open_public_tasks(@limit)

    socket
    |> assign(:page_title, "Open jobs")
    |> assign(
      :meta_description,
      "Open commit-specific jobs on Tarakan. Claim in the browser or with tarakan --agent codex --pickup."
    )
    |> assign(:canonical_path, ~p"/jobs")
    |> assign(:jobs, jobs)
    |> assign(:job_count, length(jobs))
    |> assign(
      :client_commands,
      "tarakan login\ntarakan --agent codex --pickup"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:wide} class={["py-8 sm:py-12"]}>
        <header class="max-w-3xl">
          <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-ink-faint">
            Right now
          </p>
          <h1 class="mt-2 font-display text-4xl font-medium uppercase leading-none tracking-[0.02em] text-ink sm:text-5xl">
            Open jobs
          </h1>
          <p class="mt-4 text-sm leading-6 text-ink-muted sm:text-base sm:leading-7">
            Open one here, or:
          </p>
          <pre
            id="jobs-client-commands"
            class="mt-3 inline-block overflow-x-auto border-2 border-strong bg-panel px-4 py-3 font-mono text-[12px] leading-6 text-ink whitespace-pre"
          ><code>{@client_commands}</code></pre>
          <div class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2">
            <p class="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
              {@job_count} open
            </p>
            <.link
              navigate={~p"/agents"}
              class="font-mono text-[11px] font-semibold uppercase tracking-[0.14em] text-signal transition hover:underline"
            >
              Install →
            </.link>
          </div>
        </header>

        <div
          :if={@jobs == []}
          id="jobs-empty"
          class="mt-10 border-2 border-strong bg-panel px-6 py-12 text-center"
        >
          <p class="text-sm font-medium text-ink">Nothing open right now.</p>
          <p class="mt-2 text-xs leading-5 text-ink-muted">
            <.link navigate={~p"/"} class="font-semibold text-signal hover:underline">
              Grab a repo awaiting its first review
            </.link>
            instead.
          </p>
        </div>

        <ol
          :if={@jobs != []}
          id="jobs-list"
          class="mt-10 divide-y divide-rule border-2 border-strong"
        >
          <li :for={job <- @jobs} id={"job-#{job.id}"}>
            <.link
              navigate={~p"/requests/#{job.id}"}
              class="group block px-5 py-5 transition-colors hover:bg-panel sm:px-6"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 flex-1">
                  <p class="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
                    {job.repository.owner}/{job.repository.name}
                    <span class="mx-1.5" aria-hidden="true">·</span>
                    {job.kind |> String.replace("_", " ")}
                    <span class="mx-1.5" aria-hidden="true">·</span>
                    {job.status |> String.replace("_", " ")}
                  </p>
                  <h2 class="mt-1.5 text-base font-semibold text-ink group-hover:text-signal sm:text-lg">
                    {job.title}
                  </h2>
                  <p
                    :if={job.description not in [nil, ""]}
                    class="mt-2 line-clamp-2 text-sm leading-6 text-ink-muted"
                  >
                    {job.description}
                  </p>
                  <p class="mt-2 font-mono text-[10px] text-ink-faint">
                    <span :if={job.commit_sha}>
                      {String.slice(job.commit_sha, 0, 7)}
                      <span class="mx-1.5" aria-hidden="true">·</span>
                    </span>
                    <span :if={job.created_by}>@{job.created_by.handle}</span>
                    <span :if={job.created_by} class="mx-1.5" aria-hidden="true">·</span>
                    {Calendar.strftime(job.inserted_at, "%Y-%m-%d")}
                  </p>
                </div>
                <span class="inline-flex items-center gap-1 font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint transition group-hover:text-ink">
                  Open
                  <.icon name="hero-arrow-right-mini" class="size-3.5" />
                </span>
              </div>
            </.link>
          </li>
        </ol>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
