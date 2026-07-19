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
  Shared page shell: gutters, max width, and vertical padding under the nav.

  All app pages should use this so spacing stays consistent. Pass `class` only
  for extras (e.g. `space-y-5`), not for competing padding.
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
      class={
        [
          "mx-auto w-full min-w-0 px-4 sm:px-8",
          # Consistent clearance from sticky nav + bottom breathing room.
          "pt-6 pb-10 sm:pt-10 sm:pb-12",
          @width == :wide && "max-w-[90rem]",
          @width == :focused && "max-w-3xl",
          @width == :compact && "max-w-xl",
          @width == :form && "max-w-md",
          @class
        ]
      }
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
    <div class="min-h-dvh min-w-0 overflow-x-clip bg-ground text-ink antialiased">
      <header class="sticky top-0 z-40 border-b-2 border-strong bg-ground pt-[env(safe-area-inset-top)]">
        <div
          aria-hidden="true"
          class="pointer-events-none absolute inset-x-0 -bottom-0.5 h-0.5 bg-gradient-to-r from-signal via-signal/40 to-transparent"
        >
        </div>

        <div class="flex h-14 w-full min-w-0 items-center gap-2 px-3 md:items-stretch md:gap-0 md:px-0">
          <%!-- Brand --%>
          <.link
            navigate={~p"/"}
            aria-label="Tarakan home"
            class="flex h-9 shrink-0 items-center gap-2 md:h-auto md:border-r-2 md:border-strong md:px-8"
          >
            <.logo_mark class="size-5 text-signal" />
            <span class="font-display text-[15px] font-bold uppercase tracking-[0.12em] text-ink md:text-base md:tracking-[0.14em]">
              Tarakan
            </span>
          </.link>

          <%!-- Desktop primary nav --%>
          <nav
            aria-label="Primary"
            class="hidden min-w-0 flex-1 items-stretch md:flex"
          >
            <.link
              navigate={~p"/explore"}
              class="inline-flex items-center border-r-2 border-rule px-5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-ink"
            >
              Explore
            </.link>
            <.link
              navigate={~p"/patterns"}
              class="inline-flex items-center border-r-2 border-rule px-5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-ink"
            >
              Patterns
            </.link>
            <.link
              navigate={~p"/jobs"}
              class="inline-flex items-center border-r-2 border-rule px-5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-ink"
            >
              Jobs
            </.link>
            <.link
              navigate={~p"/agents"}
              class="inline-flex items-center border-r-2 border-rule px-5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-ink"
            >
              Agents
            </.link>
            <.link
              navigate={~p"/leaderboard"}
              class="hidden items-center border-r-2 border-rule px-5 font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint transition hover:bg-panel hover:text-ink lg:inline-flex"
            >
              Leaderboard
            </.link>
          </nav>

          <%!-- Desktop utilities --%>
          <div class="ml-auto hidden h-14 items-stretch md:flex">
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
                class="flex w-10 cursor-pointer items-center justify-center text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink"
              >
                <.icon name="hero-sun-micro" class="size-3.5" />
              </button>
              <button
                type="button"
                data-theme-option="system"
                aria-pressed="false"
                aria-label="Follow system theme"
                phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "system"})}
                class="flex w-10 cursor-pointer items-center justify-center text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink"
              >
                <.icon name="hero-computer-desktop-micro" class="size-3.5" />
              </button>
              <button
                type="button"
                data-theme-option="dark"
                aria-pressed="false"
                aria-label="Dark theme"
                phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "dark"})}
                class="flex w-10 cursor-pointer items-center justify-center text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink"
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
                <summary class="flex cursor-pointer list-none items-center gap-1.5 border-l-2 border-rule px-5 font-mono text-xs text-ink-muted transition hover:bg-panel hover:text-ink [&::-webkit-details-marker]:hidden">
                  <span class="max-w-[16ch] truncate">@{@current_scope.account.handle}</span>
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
                    class="block px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.18em] text-signal transition hover:bg-panel hover:text-ink"
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
                class="inline-flex items-center gap-1.5 border-l-2 border-strong bg-btn px-5 font-display text-xs uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90"
              >
                <.icon name="hero-plus-micro" class="size-3.5" /> Add repository
              </.link>
            <% else %>
              <.link
                id="header-login"
                navigate={~p"/accounts/log-in"}
                class="inline-flex items-center border-l-2 border-rule px-5 font-display text-xs uppercase tracking-[0.14em] text-ink transition hover:bg-panel"
              >
                Sign in
              </.link>
              <.link
                id="header-register"
                navigate={~p"/accounts/register"}
                class="inline-flex items-center border-l-2 border-strong bg-btn px-5 font-display text-xs uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90"
              >
                Join Tarakan
              </.link>
            <% end %>
          </div>

          <%!-- Mobile: one primary action + menu --%>
          <div class="ml-auto flex items-center gap-1.5 md:hidden">
            <.link
              :if={@current_scope && @current_scope.account}
              id="header-add-repository-mobile"
              navigate={~p"/repositories/new"}
              class="inline-flex h-9 items-center gap-1 bg-btn px-3 font-display text-[11px] uppercase tracking-[0.12em] text-btn-fg transition hover:opacity-90"
            >
              <.icon name="hero-plus-micro" class="size-3.5" /> Add
            </.link>
            <.link
              :if={is_nil(@current_scope) || is_nil(@current_scope.account)}
              id="header-login-mobile"
              navigate={~p"/accounts/log-in"}
              class="inline-flex h-9 items-center border-2 border-strong px-3 font-display text-[11px] uppercase tracking-[0.12em] text-ink transition hover:bg-panel"
            >
              Sign in
            </.link>

            <details
              id="site-nav-mobile"
              class="relative"
              phx-click-away={JS.remove_attribute("open", to: "#site-nav-mobile")}
            >
              <summary
                class="flex h-9 w-9 cursor-pointer list-none items-center justify-center border-2 border-strong text-ink transition hover:bg-panel [&::-webkit-details-marker]:hidden"
                aria-label="Open menu"
              >
                <.icon name="hero-bars-3-mini" class="size-5" />
              </summary>

              <div class="absolute right-0 top-[calc(100%+0.4rem)] z-50 w-[min(18.5rem,calc(100vw-1.5rem))] border-2 border-strong bg-ground shadow-2xl">
                <nav aria-label="Site" class="divide-y divide-rule">
                  <.link
                    navigate={~p"/explore"}
                    class="block px-4 py-3.5 font-mono text-[11px] uppercase tracking-[0.16em] text-ink transition hover:bg-panel"
                  >
                    Explore
                  </.link>
                  <.link
                    navigate={~p"/patterns"}
                    class="block px-4 py-3.5 font-mono text-[11px] uppercase tracking-[0.16em] text-ink transition hover:bg-panel"
                  >
                    Patterns
                  </.link>
                  <.link
                    navigate={~p"/jobs"}
                    class="block px-4 py-3.5 font-mono text-[11px] uppercase tracking-[0.16em] text-ink transition hover:bg-panel"
                  >
                    Jobs
                  </.link>
                  <.link
                    navigate={~p"/agents"}
                    class="block px-4 py-3.5 font-mono text-[11px] uppercase tracking-[0.16em] text-ink transition hover:bg-panel"
                  >
                    Agents
                  </.link>
                  <.link
                    navigate={~p"/leaderboard"}
                    class="block px-4 py-3.5 font-mono text-[11px] uppercase tracking-[0.16em] text-ink transition hover:bg-panel"
                  >
                    Leaderboard
                  </.link>
                </nav>

                <div
                  id="theme-toggle-mobile"
                  class="flex border-t-2 border-strong"
                  role="group"
                  aria-label="Color theme"
                >
                  <button
                    type="button"
                    data-theme-option="light"
                    aria-pressed="false"
                    aria-label="Light theme"
                    phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "light"})}
                    class="flex h-11 flex-1 cursor-pointer items-center justify-center gap-1.5 font-mono text-[10px] uppercase tracking-[0.12em] text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink"
                  >
                    <.icon name="hero-sun-micro" class="size-3.5" /> Light
                  </button>
                  <button
                    type="button"
                    data-theme-option="system"
                    aria-pressed="false"
                    aria-label="Follow system theme"
                    phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "system"})}
                    class="flex h-11 flex-1 cursor-pointer items-center justify-center gap-1.5 border-x border-rule font-mono text-[10px] uppercase tracking-[0.12em] text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink"
                  >
                    <.icon name="hero-computer-desktop-micro" class="size-3.5" /> Auto
                  </button>
                  <button
                    type="button"
                    data-theme-option="dark"
                    aria-pressed="false"
                    aria-label="Dark theme"
                    phx-click={JS.dispatch("tarakan:set-theme", detail: %{theme: "dark"})}
                    class="flex h-11 flex-1 cursor-pointer items-center justify-center gap-1.5 font-mono text-[10px] uppercase tracking-[0.12em] text-ink-faint transition hover:bg-panel hover:text-ink aria-pressed:bg-panel aria-pressed:text-ink"
                  >
                    <.icon name="hero-moon-micro" class="size-3.5" /> Dark
                  </button>
                </div>

                <div class="border-t-2 border-strong">
                  <%= if @current_scope && @current_scope.account do %>
                    <p class="px-4 py-2.5 font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
                      @{@current_scope.account.handle}
                    </p>
                    <.link
                      id="header-profile-mobile"
                      navigate={"/" <> @current_scope.account.handle}
                      class="block px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-muted transition hover:bg-panel hover:text-ink"
                    >
                      Your profile
                    </.link>
                    <.link
                      navigate={~p"/accounts/settings"}
                      class="block px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-muted transition hover:bg-panel hover:text-ink"
                    >
                      Settings
                    </.link>
                    <.link
                      id="header-report-content-mobile"
                      navigate={~p"/moderation/report"}
                      class="block px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-muted transition hover:bg-panel hover:text-ink"
                    >
                      Report content
                    </.link>
                    <.link
                      :if={
                        @current_scope.account_state == "active" &&
                          @current_scope.platform_role in ["moderator", "admin"]
                      }
                      id="header-moderation-queue-mobile"
                      navigate={~p"/moderation/queue"}
                      class="block px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-muted transition hover:bg-panel hover:text-ink"
                    >
                      Moderation queue
                    </.link>
                    <.link
                      :if={@current_scope.platform_role == "admin"}
                      id="header-admin-dashboard-mobile"
                      navigate={~p"/admin"}
                      class="block px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-signal transition hover:bg-panel hover:text-ink"
                    >
                      Administration
                    </.link>
                    <.link
                      href={~p"/accounts/log-out"}
                      method="delete"
                      class="block px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-faint transition hover:bg-panel hover:text-signal"
                    >
                      Sign out
                    </.link>
                  <% else %>
                    <.link
                      id="header-register-mobile"
                      navigate={~p"/accounts/register"}
                      class="block bg-btn px-4 py-3.5 text-center font-mono text-[11px] uppercase tracking-[0.16em] text-btn-fg transition hover:opacity-90"
                    >
                      Join Tarakan
                    </.link>
                  <% end %>
                </div>
              </div>
            </details>
          </div>
        </div>
      </header>

      <main class="min-w-0">
        {render_slot(@inner_block)}
      </main>

      <footer class="relative overflow-hidden border-t-2 border-strong pb-[env(safe-area-inset-bottom)]">
        <div class="mx-auto flex w-full max-w-[90rem] flex-col gap-6 px-4 py-10 sm:px-8 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="flex items-center gap-2.5 font-display text-base font-bold uppercase tracking-[0.08em] text-ink">
              <.logo_mark class="size-5 text-signal" /> Tarakan
            </p>
            <p class="mt-3 max-w-xs text-sm leading-6 text-ink-muted">
              Public disclosure by default.
            </p>
          </div>

          <nav aria-label="Footer" class="text-sm">
            <ul class="flex flex-wrap gap-x-5 gap-y-2.5">
              <li>
                <.link navigate={~p"/"} class="text-ink-muted transition hover:text-ink">
                  Registry
                </.link>
              </li>
              <li>
                <.link navigate={~p"/jobs"} class="text-ink-muted transition hover:text-ink">
                  Jobs
                </.link>
              </li>
              <li>
                <.link navigate={~p"/agents"} class="text-ink-muted transition hover:text-ink">
                  Agents
                </.link>
              </li>
              <li>
                <.link navigate={~p"/explore"} class="text-ink-muted transition hover:text-ink">
                  Explore
                </.link>
              </li>
              <li>
                <.link navigate={~p"/leaderboard"} class="text-ink-muted transition hover:text-ink">
                  Leaderboard
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
