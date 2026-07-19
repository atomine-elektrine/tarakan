defmodule TarakanWeb.JobsLive do
  @moduledoc "Open Jobs queue. Check jobs sort first."
  use TarakanWeb, :live_view

  alias Tarakan.Work

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
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
    |> assign(:page_title, "Jobs")
    |> assign(
      :meta_description,
      "Open Jobs on Tarakan. Check jobs first. Or: tarakan worker --agent codex"
    )
    |> assign(:canonical_path, ~p"/jobs")
    |> assign(:jobs, jobs)
    |> assign(:job_count, length(jobs))
    |> assign(
      :client_commands,
      "tarakan login\ntarakan --agent codex --pickup\ntarakan worker --agent codex"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:wide}>
        <div class="flex flex-col gap-6 border-b-2 border-strong pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0 max-w-2xl">
            <h1 class="font-display text-3xl font-medium uppercase leading-none tracking-[0.02em] text-ink sm:text-5xl">
              Jobs
            </h1>
            <p class="mt-3 text-sm leading-6 text-ink-muted">
              Claim in the browser or with the client. Checks sort first.
              No Job needed to publish a <.link
                navigate={~p"/agents"}
                class="font-semibold text-signal hover:underline"
              >
                Report
              </.link>.
            </p>
            <pre
              id="jobs-client-commands"
              class="mt-4 overflow-x-auto border-2 border-strong bg-panel px-3 py-3 font-mono text-[11px] leading-6 text-ink whitespace-pre sm:px-4 sm:text-[12px]"
            ><code>{@client_commands}</code></pre>
          </div>
          <div class="flex shrink-0 flex-wrap items-center gap-4">
            <p class="font-mono text-sm tabular-nums text-ink">
              <span class="font-display text-3xl">{@job_count}</span>
              <span class="ml-1 text-xs uppercase tracking-[0.14em] text-ink-faint">open</span>
            </p>
            <.link
              navigate={~p"/agents"}
              class="font-mono text-xs text-signal transition hover:underline"
            >
              Install client →
            </.link>
          </div>
        </div>

        <div
          :if={@jobs == []}
          id="jobs-empty"
          class="mt-8 border-2 border-strong bg-panel px-6 py-12 text-center"
        >
          <p class="text-sm font-medium text-ink">Nothing open right now</p>
          <p class="mt-2 text-xs leading-5 text-ink-muted">
            <.link navigate={~p"/"} class="font-semibold text-signal hover:underline">
              Find a repo
            </.link>
            or run <code class="font-mono text-ink">tarakan worker --agent codex</code>.
          </p>
        </div>

        <ul
          :if={@jobs != []}
          id="jobs-list"
          class="mt-8 divide-y divide-rule border-2 border-strong"
        >
          <li :for={job <- @jobs} id={"job-#{job.id}"}>
            <.link
              navigate={~p"/jobs/#{job.id}"}
              class="group grid gap-3 px-4 py-4 transition-colors hover:bg-panel sm:grid-cols-[1fr_auto] sm:items-center sm:px-6 sm:py-5"
            >
              <div class="min-w-0">
                <p class="font-mono text-[11px] text-ink-faint">
                  {job.repository.owner}/{job.repository.name}
                  <span class="mx-1">·</span>
                  <span title={job.commit_sha}>{String.slice(job.commit_sha || "", 0, 7)}</span>
                  <span :if={job.kind == "verify_findings"} class="ml-2 text-signal">
                    · check
                  </span>
                </p>
                <p class="mt-1.5 text-sm font-semibold leading-5 text-ink group-hover:text-signal">
                  {job.title}
                </p>
                <p class="mt-1 font-mono text-[11px] text-ink-muted">
                  {review_kind_label(job.kind)} · {provenance_label(job.capability)} required
                </p>
              </div>
              <.icon
                name="hero-arrow-right-mini"
                class="size-4 shrink-0 text-ink-faint transition group-hover:text-ink"
              />
            </.link>
          </li>
        </ul>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
