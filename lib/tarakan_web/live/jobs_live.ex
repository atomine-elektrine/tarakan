defmodule TarakanWeb.JobsLive do
  @moduledoc """
  Public contribution queue: open security jobs anyone can claim.
  """
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
    |> assign(:page_title, "Open jobs")
    |> assign(
      :meta_description,
      "Open security jobs on Tarakan. Claim in the browser or with tarakan --agent codex --pickup."
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
      <Layouts.page width={:wide}>
        <div class="flex flex-col gap-6 border-b-2 border-strong pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0 max-w-2xl">
            <h1 class="font-display text-4xl font-medium uppercase leading-none tracking-[0.02em] text-ink sm:text-5xl">
              Open jobs
            </h1>
            <p class="mt-3 text-sm leading-6 text-ink-muted">
              Claim in the browser, or let a local agent pick the next one up.
            </p>
            <pre
              id="jobs-client-commands"
              class="mt-4 overflow-x-auto border-2 border-strong bg-panel px-4 py-3 font-mono text-[12px] leading-6 text-ink whitespace-pre"
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
            and open a job, or wait for auto check jobs after a report.
          </p>
        </div>

        <ul
          :if={@jobs != []}
          id="jobs-list"
          class="mt-8 divide-y divide-rule border-2 border-strong"
        >
          <li :for={job <- @jobs} id={"job-#{job.id}"}>
            <.link
              navigate={~p"/requests/#{job.id}"}
              class="group grid gap-3 px-5 py-5 transition-colors hover:bg-panel sm:grid-cols-[1fr_auto] sm:items-center sm:px-6"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-mono text-xs font-semibold text-ink">
                    {job.repository.owner}/{job.repository.name}
                  </span>
                  <.notch_badge class="text-ink-muted">
                    {job_kind_label(job.kind)}
                  </.notch_badge>
                  <.notch_badge class="text-ink-faint">
                    {job_capability_label(job.capability)}
                  </.notch_badge>
                  <span
                    :if={job.commit_sha}
                    class="font-mono text-[10px] text-ink-faint"
                    title={job.commit_sha}
                  >
                    {String.slice(job.commit_sha, 0, 7)}
                  </span>
                </div>
                <h2 class="mt-2 text-base font-semibold leading-snug text-ink group-hover:text-signal sm:text-lg">
                  {job.title}
                </h2>
                <p
                  :if={job.description not in [nil, ""]}
                  class="mt-1.5 line-clamp-2 max-w-3xl text-sm leading-6 text-ink-muted"
                >
                  {job.description}
                </p>
                <p class="mt-2 font-mono text-[10px] text-ink-faint">
                  <span :if={job.created_by}>@{job.created_by.handle}</span>
                  <span :if={job.created_by} class="mx-1.5" aria-hidden="true">·</span>
                  {Calendar.strftime(job.inserted_at, "%Y-%m-%d")}
                </p>
              </div>
              <span class="inline-flex items-center justify-end gap-1 font-display text-[11px] uppercase tracking-[0.16em] text-ink-faint transition group-hover:text-signal">
                Open <.icon name="hero-arrow-right-mini" class="size-3.5" />
              </span>
            </.link>
          </li>
        </ul>
      </Layouts.page>
    </Layouts.app>
    """
  end

  defp job_kind_label("code_review"), do: "Security report"
  defp job_kind_label("verify_findings"), do: "Check report"
  defp job_kind_label("threat_model"), do: "Threat model"
  defp job_kind_label("privacy_review"), do: "Privacy"
  defp job_kind_label("business_logic"), do: "Business logic"
  defp job_kind_label("write_fix"), do: "Write fix"
  defp job_kind_label(other) when is_binary(other), do: String.replace(other, "_", " ")
  defp job_kind_label(_), do: "Job"

  defp job_capability_label("agent"), do: "Agent"
  defp job_capability_label("human"), do: "Human"
  defp job_capability_label("hybrid"), do: "Hybrid"
  defp job_capability_label(other) when is_binary(other), do: other
  defp job_capability_label(_), do: ""
end
