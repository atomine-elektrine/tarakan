defmodule TarakanWeb.RepositoryComponents do
  @moduledoc """
  Shared repository page chrome.

  Every repository-scoped page renders the same header at the same scale:
  status badge row, display-face title, canonical source link, host metadata,
  and the Code / Security tab rail. Page bodies differ; the frame does not.
  """

  use Phoenix.Component

  import TarakanWeb.CoreComponents,
    only: [icon: 1, breadcrumbs: 1, handle_link: 1, notch_badge: 1]

  alias TarakanWeb.RepositoryPaths

  @doc ~S'Formats a star count compactly (`1200` -> `"1.2k"`); `nil` -> `"0"`.'
  def compact_stars(count) when is_integer(count) and count >= 1000,
    do: "#{Float.round(count / 1000, 1)}k"

  def compact_stars(count) when is_integer(count), do: Integer.to_string(count)
  def compact_stars(_count), do: "0"

  attr :repository, Tarakan.Repositories.Repository, required: true
  attr :active_tab, :atom, required: true, values: [:code, :security]

  def repository_header(assigns) do
    ~H"""
    <header>
      <.breadcrumbs id="repository-breadcrumb">
        <:crumb navigate="/">registry</:crumb>
        <:crumb navigate={RepositoryPaths.repository_path(@repository)}>
          {@repository.owner}
        </:crumb>
        <:crumb navigate={RepositoryPaths.repository_path(@repository)}>
          {@repository.name}
        </:crumb>
      </.breadcrumbs>

      <div class="flex flex-wrap items-center gap-3">
        <.notch_badge id="repository-status" class={status_badge_class(@repository.status)}>
          {@repository.status}
        </.notch_badge>
        <span class="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
          public record
        </span>
        <.notch_badge :if={@repository.archived} class="text-signal">
          archived
        </.notch_badge>
      </div>

      <div class="mt-3 flex flex-col justify-between gap-4 lg:flex-row lg:items-end">
        <div class="min-w-0">
          <h1
            id="repository-name"
            class="break-words font-display text-2xl font-medium uppercase leading-tight tracking-[0.02em] text-ink sm:text-3xl"
          >
            <span class="text-ink-faint">{@repository.owner}/</span>{@repository.name}
          </h1>
          <p :if={@repository.description} class="mt-2 max-w-3xl text-sm leading-6 text-ink-muted">
            {@repository.description}
          </p>
        </div>
        <a
          :if={not Tarakan.Repositories.Repository.hosted?(@repository)}
          id="repository-source-link"
          href={@repository.canonical_url}
          rel="noreferrer"
          target="_blank"
          class="inline-flex shrink-0 items-center gap-2 font-mono text-xs text-ink-muted transition hover:text-signal"
        >
          {@repository.canonical_url}
          <.icon name="hero-arrow-up-right" class="size-4" />
        </a>
      </div>

      <div
        id="github-metadata"
        class="mt-4 flex flex-wrap items-center gap-x-5 gap-y-2 font-mono text-xs text-ink-faint"
      >
        <span :if={@repository.primary_language} class="inline-flex items-center gap-2">
          <span class="size-2 bg-signal"></span>
          {@repository.primary_language}
        </span>
        <span
          :if={not Tarakan.Repositories.Repository.hosted?(@repository)}
          class="inline-flex items-center gap-1.5"
        >
          <.icon name="hero-star" class="size-3.5" /> {@repository.stars_count} stars
        </span>
        <span
          :if={not Tarakan.Repositories.Repository.hosted?(@repository)}
          class="inline-flex items-center gap-1.5"
        >
          <.icon name="hero-code-bracket" class="size-3.5" /> {@repository.forks_count} forks
        </span>
        <span :if={Tarakan.Repositories.Repository.hosted?(@repository)}>hosted on tarakan</span>
        <span :if={@repository.default_branch}>default: {@repository.default_branch}</span>
        <span class="inline-flex items-center gap-1.5">
          <.icon name="hero-clock" class="size-3.5" />
          registered {Calendar.strftime(
            @repository.inserted_at,
            "%Y-%m-%d"
          )}
        </span>
        <span :if={@repository.submitted_by} id="repository-submitter">
          by <.handle_link handle={@repository.submitted_by.handle} class="text-ink-muted" />
        </span>
      </div>

      <nav
        id="repository-navigation"
        class="mt-5 flex items-end gap-1 border-b border-rule text-sm"
        aria-label="Repository"
      >
        <.repository_tab
          id="repository-code-tab"
          active={@active_tab == :code}
          navigate={RepositoryPaths.repository_path(@repository)}
          icon="hero-code-bracket"
          label="Code"
        />
        <.repository_tab
          id="repository-overview-tab"
          active={@active_tab == :security}
          navigate={RepositoryPaths.repository_security_path(@repository)}
          icon="hero-shield-check"
          label="Security"
        >
          <span
            :if={@repository.open_findings_count > 0}
            class="rounded-full bg-signal px-1.5 py-0.5 font-mono text-[9px] leading-none text-ground"
          >
            {@repository.open_findings_count}
          </span>
        </.repository_tab>
      </nav>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :active, :boolean, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  slot :inner_block

  defp repository_tab(%{active: true} = assigns) do
    ~H"""
    <span
      id={@id}
      aria-current="page"
      class="-mb-px inline-flex items-center gap-2 border-b-2 border-signal px-4 py-3 font-semibold text-ink"
    >
      <.icon name={@icon} class="size-4" /> {@label} {render_slot(@inner_block)}
    </span>
    """
  end

  defp repository_tab(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="-mb-px inline-flex items-center gap-2 border-b-2 border-transparent px-4 py-3 text-ink-muted transition hover:border-rule hover:text-ink"
    >
      <.icon name={@icon} class="size-4" /> {@label} {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  The scan's submitted Tarakan Scan Format document, pretty-printed for the
  raw-report block. Returns the stored text unchanged when it isn't JSON.
  """
  def raw_report(%{raw_document: nil}), do: nil

  def raw_report(%{raw_document: raw_document}) do
    Jason.Formatter.pretty_print(raw_document)
  rescue
    _not_json -> raw_document
  end

  @doc "Human-readable label for a review/task provenance capability."
  def provenance_label("agent"), do: "Agent-generated"
  def provenance_label("human"), do: "Human-authored"
  def provenance_label("hybrid"), do: "Human-guided"
  def provenance_label(other), do: other

  @doc "Human-readable label for a review or task kind."
  def review_kind_label("code_review"), do: "Code review"
  def review_kind_label("threat_model"), do: "Threat model"
  def review_kind_label("privacy_review"), do: "Privacy review"
  def review_kind_label("business_logic"), do: "Business logic"
  def review_kind_label("verify_findings"), do: "Verify findings"
  def review_kind_label("write_fix"), do: "Write a fix"
  def review_kind_label(other), do: other

  defp status_badge_class("findings"), do: "text-signal"
  defp status_badge_class("unscanned"), do: "text-ink-faint"
  defp status_badge_class(_status), do: "text-ink-muted"
end
