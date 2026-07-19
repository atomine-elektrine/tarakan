defmodule TarakanWeb.EpidemicLive.Show do
  @moduledoc "One cross-repo epidemic pattern: affected repos and instances."
  use TarakanWeb, :live_view

  alias Tarakan.Epidemics
  alias Tarakan.Policy

  @graph_limit 64
  @ledger_page 50

  @impl true
  def mount(%{"pattern_key" => pattern_key}, _session, socket) do
    epidemic = Epidemics.get_epidemic(pattern_key)

    if is_nil(epidemic) or epidemic.repo_count < 1 do
      raise Ecto.NoResultsError, queryable: Tarakan.Scans.CanonicalFinding
    end

    graph = Epidemics.list_pattern_repos_page(pattern_key, limit: @graph_limit)
    ledger = Epidemics.list_instances_page(pattern_key, limit: @ledger_page)

    # Swarm / checks still use list shape (compat).
    instances_for_swarm = Epidemics.list_instances(pattern_key, limit: 200)

    {:ok,
     socket
     |> assign(:page_title, epidemic.title)
     |> assign(
       :meta_description,
       "#{epidemic.title}. Seen in #{epidemic.repo_count} listed repositories on Tarakan."
     )
     |> assign(:canonical_path, ~p"/patterns/#{pattern_key}")
     |> assign(:pattern_key, pattern_key)
     |> assign(:epidemic, epidemic)
     |> assign(:graph_repos, graph.entries)
     |> assign(:graph_hidden, max(epidemic.repo_count - length(graph.entries), 0))
     |> stream(:ledger_instances, ledger.entries, reset: true)
     |> assign(:ledger_cursor, ledger.next_cursor)
     |> assign(:ledger_empty?, ledger.entries == [])
     |> assign(:instances, instances_for_swarm)
     |> assign(
       :can_swarm,
       Policy.allowed?(socket.assigns.current_scope, :moderate)
     )}
  end

  @impl true
  def handle_event("swarm_checks", _params, socket) do
    if socket.assigns.can_swarm do
      case Epidemics.swarm_check_jobs(socket.assigns.current_scope, socket.assigns.pattern_key) do
        {:ok, %{opened: opened, skipped: skipped, failed: failed}} ->
          msg =
            "Opened #{opened} check job(s). Skipped #{skipped}. Failed #{failed}."

          {:noreply, put_flash(socket, :info, msg)}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "Not authorized.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not open swarm jobs.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    end
  end

  def handle_event("load_more_instances", _params, socket) do
    case socket.assigns.ledger_cursor do
      nil ->
        {:noreply, socket}

      cursor ->
        page =
          Epidemics.list_instances_page(socket.assigns.pattern_key,
            limit: @ledger_page,
            cursor: cursor
          )

        {:noreply,
         socket
         |> stream(:ledger_instances, page.entries)
         |> assign(:ledger_cursor, page.next_cursor)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:wide}>
        <.breadcrumbs id="epidemic-breadcrumb">
          <:crumb navigate={~p"/"}>registry</:crumb>
          <:crumb navigate={~p"/patterns"}>patterns</:crumb>
          <:crumb>pattern</:crumb>
        </.breadcrumbs>

        <div class="mt-4 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0 max-w-3xl">
            <h1 class="font-display text-2xl font-medium leading-tight tracking-[0.01em] text-ink sm:text-4xl">
              {@epidemic.title}
            </h1>
            <p
              :if={@epidemic.severity}
              class="mt-2 font-mono text-xs text-signal"
            >
              {@epidemic.severity}
            </p>
          </div>
          <button
            :if={@can_swarm}
            id="epidemic-swarm-checks"
            type="button"
            phx-click="swarm_checks"
            data-confirm="Open check jobs for open instances of this pattern (budgeted per repo)?"
            class="shrink-0 border-2 border-strong bg-btn px-4 py-2 font-mono text-[11px] uppercase tracking-[0.12em] text-btn-fg transition hover:opacity-90"
          >
            Swarm check jobs
          </button>
        </div>

        <div class="mt-6 grid gap-px border-2 border-strong bg-rule sm:grid-cols-4">
          <div class="bg-ground px-4 py-4">
            <p class="text-xs font-medium text-ink-faint">Repos</p>
            <p id="epidemic-repo-count" class="mt-1 font-display text-3xl tabular-nums text-ink">
              {@epidemic.repo_count}
            </p>
          </div>
          <div class="bg-ground px-4 py-4">
            <p class="text-xs font-medium text-ink-faint">Open</p>
            <p class="mt-1 font-display text-3xl tabular-nums text-phosphor">
              {@epidemic.open_count}
            </p>
          </div>
          <div class="bg-ground px-4 py-4">
            <p class="text-xs font-medium text-ink-faint">Verified</p>
            <p class="mt-1 font-display text-3xl tabular-nums text-ink">
              {@epidemic.verified_count}
            </p>
          </div>
          <div class="bg-ground px-4 py-4">
            <p class="text-xs font-medium text-ink-faint">Fixed</p>
            <p class="mt-1 font-display text-3xl tabular-nums text-ink-muted">
              {@epidemic.fixed_count}
            </p>
          </div>
        </div>

        <section class="mt-8">
          <h2 class="mb-3 font-display text-lg uppercase tracking-[0.08em] text-ink">
            Affected repositories
          </h2>
          <.contagion_graph
            id="epidemic-contagion"
            epidemic={@epidemic}
            instances={graph_instances(@graph_repos)}
            pattern_key={@pattern_key}
          />
          <p
            :if={@graph_hidden > 0}
            id="epidemic-graph-more"
            class="mt-3 font-mono text-[11px] text-ink-faint"
          >
            +{@graph_hidden} more in instance table
          </p>
        </section>

        <section id="epidemic-instances" class="mt-10">
          <h2 class="mb-3 font-display text-lg uppercase tracking-[0.08em] text-ink">
            Instances
          </h2>

          <p :if={@ledger_empty?} class="mt-4 font-mono text-xs text-ink-faint">No instances.</p>

          <ul
            id="epidemic-ledger"
            phx-update="stream"
            class="mt-4 divide-y divide-rule border-2 border-strong"
          >
            <li
              :for={{dom_id, instance} <- @streams.ledger_instances}
              id={dom_id}
              class="grid gap-2 px-4 py-4 sm:grid-cols-[auto_1fr_auto] sm:items-center sm:px-6"
            >
              <span class={[
                "size-2.5 shrink-0 rounded-full",
                instance.status == "open" && "bg-phosphor",
                instance.status == "verified" && "bg-ink",
                instance.status == "fixed" && "bg-ink-muted",
                instance.status not in ["open", "verified", "fixed"] && "bg-ink-faint"
              ]}></span>
              <div class="min-w-0">
                <p class="font-mono text-[10px] uppercase tracking-[0.12em] text-ink-faint">
                  {instance.owner}/{instance.name}
                  <span class="mx-1">·</span>
                  {instance.status}
                  <span :if={instance[:commit_sha]} class="mx-1">·</span>
                  <span :if={instance[:commit_sha]} title={instance.commit_sha}>
                    {String.slice(instance.commit_sha || "", 0, 7)}
                  </span>
                </p>
                <p class="mt-1 truncate font-mono text-xs text-ink-muted">
                  {instance.file_path}
                </p>
              </div>
              <.link
                :if={instance.occurrence_public_id}
                navigate={~p"/findings/#{instance.occurrence_public_id}"}
                class="font-mono text-xs text-signal hover:underline"
              >
                Open →
              </.link>
            </li>
          </ul>

          <button
            :if={@ledger_cursor}
            id="epidemic-load-more"
            type="button"
            phx-click="load_more_instances"
            class="mt-4 border-2 border-strong bg-panel px-4 py-2 font-mono text-[11px] uppercase tracking-[0.12em] text-ink transition hover:border-signal"
          >
            Load more
          </button>
        </section>
      </Layouts.page>
    </Layouts.app>
    """
  end

  # Repo matrix expects instance-shaped maps (status, owner, name, occurrence_public_id, id).
  defp graph_instances(repos) do
    Enum.map(repos, fn r ->
      %{
        id: r.repository_id,
        owner: r.owner,
        name: r.name,
        status: r.status,
        occurrence_public_id: r.occurrence_public_id,
        commit_sha: nil,
        file_path: nil
      }
    end)
  end
end
