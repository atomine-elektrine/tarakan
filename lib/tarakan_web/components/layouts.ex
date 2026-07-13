defmodule TarakanWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TarakanWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The Tarakan mark: the letter Ж with Russo One's proportions - vertical tip
  stubs, thick diagonals, pinched waist - rebuilt from straight facets only.
  The Cyrillic letterform is shaped like an insect, and tarakan is the
  Russian word for cockroach, so the mark is the name. Drawn in currentColor.
  """
  attr :class, :any, default: "size-5"

  def logo_mark(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <rect x="10.5" y="3.5" width="3" height="17" />
      <polygon points="3.4,3.5 7.3,3.5 7.3,5.2 12,7.9 12,12 3.4,7.0" />
      <polygon points="20.6,3.5 16.7,3.5 16.7,5.2 12,7.9 12,12 20.6,7.0" />
      <polygon points="3.4,20.5 7.3,20.5 7.3,18.8 12,16.1 12,12 3.4,17.0" />
      <polygon points="20.6,20.5 16.7,20.5 16.7,18.8 12,16.1 12,12 20.6,17.0" />
    </svg>
    """
  end

  @doc """
  Provides the shared horizontal rail for application pages.

  Wide pages use the full application canvas, while focused tasks and forms
  keep a deliberate reading width without changing the responsive gutters.
  """
  attr :id, :string, default: nil
  attr :width, :atom, default: :wide, values: [:wide, :focused, :compact, :form]
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "mx-auto w-full min-w-0 px-5 sm:px-8",
        @width == :wide && "max-w-[90rem]",
        @width == :focused && "max-w-3xl",
        @width == :compact && "max-w-xl",
        @width == :form && "max-w-md",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-ground text-ink antialiased">
      <header class="sticky top-0 z-40 border-b-2 border-strong bg-ground">
        <div
          aria-hidden="true"
          class="absolute inset-x-0 -bottom-0.5 h-0.5 bg-gradient-to-r from-phosphor via-phosphor/25 to-transparent"
        >
        </div>
        <div class="flex h-14 w-full items-stretch justify-between">
          <div class="flex items-stretch">
            <.link
              navigate={~p"/"}
              aria-label="Tarakan home"
              class="flex items-center gap-2.5 border-r-2 border-strong px-4 sm:px-8"
            >
              <.logo_mark class="size-5 text-ink" />
              <span class="hidden font-display text-base font-bold uppercase tracking-[0.08em] text-ink sm:inline">
                Tarakan
              </span>
            </.link>
            <.link
              navigate={~p"/explore"}
              class="hidden items-center border-r-2 border-rule px-5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-ink sm:flex"
            >
              Explore
            </.link>
            <.link
              navigate={~p"/leaderboard"}
              class="hidden items-center border-r-2 border-rule px-5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-ink sm:flex"
            >
              Leaderboard
            </.link>
          </div>

          <div class="flex items-stretch">
            <div
              id="theme-toggle"
              class="flex items-stretch border-l-2 border-rule"
              role="group"
              aria-label="Color theme"
            >
              <button
                type="button"
                data-theme-option="light"
                aria-pressed="false"
                aria-label="Light theme"
                phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "light"})}
                class="flex w-8 cursor-pointer items-center justify-center text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink sm:w-10"
              >
                <.icon name="hero-sun-micro" class="size-3.5" />
              </button>
              <button
                type="button"
                data-theme-option="system"
                aria-pressed="false"
                aria-label="Follow system theme"
                phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "system"})}
                class="flex w-8 cursor-pointer items-center justify-center text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink sm:w-10"
              >
                <.icon name="hero-computer-desktop-micro" class="size-3.5" />
              </button>
              <button
                type="button"
                data-theme-option="dark"
                aria-pressed="false"
                aria-label="Dark theme"
                phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "dark"})}
                class="flex w-8 cursor-pointer items-center justify-center text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink sm:w-10"
              >
                <.icon name="hero-moon-micro" class="size-3.5" />
              </button>
            </div>
            <%= if @current_scope && @current_scope.account do %>
              <details
                id="current-account"
                class="relative flex items-stretch"
                phx-click-away={JS.remove_attribute("open", to: "#current-account")}
              >
                <summary class="flex cursor-pointer list-none items-center gap-1.5 border-l-2 border-rule px-3 font-mono text-xs text-ink-muted transition hover:bg-panel hover:text-ink sm:px-5 [&::-webkit-details-marker]:hidden">
                  <span class="max-w-24 truncate sm:max-w-[24ch]">
                    @{@current_scope.account.handle}
                  </span>
                  <.icon name="hero-chevron-down-micro" class="size-3 shrink-0 text-ink-faint" />
                </summary>
                <nav
                  aria-label="Account"
                  class="absolute right-0 top-full z-50 w-56 divide-y divide-rule border-2 border-strong bg-ground shadow-2xl"
                >
                  <.link
                    id="header-profile"
                    navigate={"/" <> @current_scope.account.handle}
                    class="block px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-muted transition hover:bg-panel hover:text-ink"
                  >
                    Your profile
                  </.link>
                  <.link
                    navigate={~p"/accounts/settings"}
                    class="block px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-muted transition hover:bg-panel hover:text-ink"
                  >
                    Settings
                  </.link>
                  <.link
                    id="header-report-content"
                    navigate={~p"/moderation/report"}
                    class="block px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-muted transition hover:bg-panel hover:text-ink"
                  >
                    Report content
                  </.link>
                  <.link
                    :if={
                      @current_scope.account_state == "active" &&
                        @current_scope.platform_role in ["moderator", "admin"]
                    }
                    id="header-moderation-queue"
                    navigate={~p"/moderation/queue"}
                    class="block px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-muted transition hover:bg-panel hover:text-ink"
                  >
                    Moderation queue
                  </.link>
                  <.link
                    :if={@current_scope.platform_role == "admin"}
                    id="header-admin-dashboard"
                    navigate={~p"/admin"}
                    class={[
                      "block px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.18em] text-signal transition hover:bg-panel hover:text-ink"
                    ]}
                  >
                    Administration
                  </.link>
                  <.link
                    href={~p"/accounts/log-out"}
                    method="delete"
                    class="block px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-signal"
                  >
                    Sign out
                  </.link>
                </nav>
              </details>
              <.link
                id="header-add-repository"
                navigate={~p"/repositories/new"}
                class="flex items-center gap-1.5 border-l-2 border-strong bg-btn px-3 font-display text-xs uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90 sm:px-5"
              >
                <.icon name="hero-plus-micro" class="size-3.5" />
                <span class="hidden sm:inline">Add repository</span>
                <span class="sm:hidden">Add</span>
              </.link>
            <% else %>
              <.link
                id="header-login"
                navigate={~p"/accounts/log-in"}
                class="flex items-center border-l-2 border-rule px-4 font-display text-xs uppercase tracking-[0.14em] text-ink transition hover:bg-panel sm:px-5"
              >
                Sign in
              </.link>
              <.link
                id="header-register"
                navigate={~p"/accounts/register"}
                class="hidden items-center border-l-2 border-strong bg-btn px-5 font-display text-xs uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90 sm:flex"
              >
                Join Tarakan
              </.link>
            <% end %>
          </div>
        </div>
      </header>

      <main>
        {render_slot(@inner_block)}
      </main>

      <footer class="relative overflow-hidden border-t-2 border-strong">
        <div class="mx-auto flex w-full max-w-[90rem] flex-col gap-6 px-5 py-10 sm:px-8 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="flex items-center gap-2.5 font-display text-base font-bold uppercase tracking-[0.08em] text-ink">
              <.logo_mark class="size-5" /> Tarakan
            </p>
            <p class="mt-3 max-w-xs text-sm leading-6 text-ink-muted">
              The public security record for open source.
            </p>
          </div>

          <nav aria-label="Footer" class="text-sm">
            <ul class="flex flex-wrap gap-x-6 gap-y-2">
              <li>
                <.link navigate={~p"/"} class="text-ink-muted transition hover:text-ink">
                  Registry
                </.link>
              </li>
              <%= if @current_scope && @current_scope.account do %>
                <li>
                  <.link
                    navigate={~p"/moderation/report"}
                    class="text-ink-muted transition hover:text-ink"
                  >
                    Report content
                  </.link>
                </li>
                <li :if={
                  @current_scope.account_state == "active" &&
                    @current_scope.platform_role in ["moderator", "admin"]
                }>
                  <.link
                    navigate={~p"/moderation/queue"}
                    class="text-ink-muted transition hover:text-ink"
                  >
                    Moderation queue
                  </.link>
                </li>
                <li :if={@current_scope.platform_role == "admin"}>
                  <.link
                    id="footer-admin-dashboard"
                    navigate={~p"/admin"}
                    class={["text-signal transition hover:text-ink"]}
                  >
                    Administration
                  </.link>
                </li>
                <li>
                  <.link
                    navigate={~p"/accounts/settings"}
                    class="text-ink-muted transition hover:text-ink"
                  >
                    Settings
                  </.link>
                </li>
                <li>
                  <.link
                    href={~p"/accounts/log-out"}
                    method="delete"
                    class="text-ink-muted transition hover:text-ink"
                  >
                    Sign out
                  </.link>
                </li>
              <% else %>
                <li>
                  <.link
                    navigate={~p"/accounts/register"}
                    class="text-ink-muted transition hover:text-ink"
                  >
                    Join Tarakan
                  </.link>
                </li>
                <li>
                  <.link
                    navigate={~p"/accounts/log-in"}
                    class="text-ink-muted transition hover:text-ink"
                  >
                    Sign in
                  </.link>
                </li>
              <% end %>
            </ul>
          </nav>
        </div>
      </footer>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
