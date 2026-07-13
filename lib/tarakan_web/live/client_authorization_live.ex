defmodule TarakanWeb.ClientAuthorizationLive do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts
  alias Tarakan.Accounts.ClientAuthorizations
  alias TarakanWeb.AccountAuth

  @impl true
  def mount(%{"user_code" => user_code}, _session, socket) do
    if Accounts.sudo_mode?(socket.assigns.current_scope.account) do
      case ClientAuthorizations.get_for_browser(user_code) do
        {:ok, authorization} ->
          {:ok,
           socket
           |> assign(:authorization, authorization)
           |> assign(
             :display_code,
             ClientAuthorizations.display_user_code(authorization.user_code)
           )
           |> assign(:page_title, "Authorize Tarakan Client")}

        {:error, :not_found} ->
          {:ok,
           socket
           |> assign(:authorization, nil)
           |> assign(:display_code, user_code)
           |> assign(:page_title, "Login request expired")}
      end
    else
      return_to = ~p"/client/authorize/#{user_code}"

      {:ok,
       socket
       |> put_flash(:error, "Confirm it's you before authorizing Tarakan Client.")
       |> redirect(to: AccountAuth.reauth_path(return_to))}
    end
  end

  @impl true
  def handle_event(action, _params, %{assigns: %{authorization: nil}} = socket)
      when action in ["approve", "deny"] do
    {:noreply, put_flash(socket, :error, "This login request has expired or was already used.")}
  end

  def handle_event("approve", _params, socket) do
    account = socket.assigns.current_scope.account

    case ClientAuthorizations.approve(socket.assigns.authorization, account) do
      {:ok, authorization} ->
        {:noreply,
         socket
         |> assign(:authorization, authorization)
         |> put_flash(:info, "Tarakan Client authorized. You can return to your terminal.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:authorization, nil)
         |> put_flash(:error, "This login request has expired or was already used.")}
    end
  end

  def handle_event("deny", _params, socket) do
    account = socket.assigns.current_scope.account

    case ClientAuthorizations.deny(socket.assigns.authorization, account) do
      {:ok, authorization} ->
        {:noreply,
         socket
         |> assign(:authorization, authorization)
         |> put_flash(:info, "Tarakan Client access denied.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :authorization, nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page
        id="client-authorization-page"
        width={:compact}
        class={["py-12 sm:py-20"]}
      >
        <section class={[
          "border-2 border-strong bg-panel p-6 shadow-[8px_8px_0_0_var(--color-rule)] sm:p-8"
        ]}>
          <div class={["flex items-start gap-4"]}>
            <div class={[
              "flex size-11 shrink-0 items-center justify-center border-2 border-strong bg-well text-ink"
            ]}>
              <.icon name="hero-command-line" class={["size-6"]} />
            </div>
            <div>
              <p class={["font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint"]}>
                Device authorization
              </p>
              <h1 class={["mt-1 font-display text-2xl uppercase tracking-[0.04em] text-ink"]}>
                Sign in to Tarakan Client
              </h1>
            </div>
          </div>

          <%= cond do %>
            <% is_nil(@authorization) -> %>
              <div id="client-authorization-expired" class={["mt-8 border-2 border-rule p-5"]}>
                <p class={["font-semibold text-ink"]}>This login request is invalid or expired.</p>
                <p class={["mt-2 text-sm leading-6 text-ink-muted"]}>
                  Return to your terminal and run
                  <span class={["font-mono text-ink"]}>tarakan login</span>
                  again.
                </p>
              </div>
            <% @authorization.status == "approved" -> %>
              <div
                id="client-authorization-approved"
                class={["mt-8 border-2 border-strong bg-well p-5"]}
              >
                <p class={["font-semibold text-ink"]}>Authorized</p>
                <p class={["mt-2 text-sm leading-6 text-ink-muted"]}>
                  The terminal will finish signing in automatically. You can close this tab.
                </p>
              </div>
            <% @authorization.status == "denied" -> %>
              <div id="client-authorization-denied" class={["mt-8 border-2 border-rule p-5"]}>
                <p class={["font-semibold text-ink"]}>Access denied</p>
                <p class={["mt-2 text-sm leading-6 text-ink-muted"]}>You can close this tab.</p>
              </div>
            <% true -> %>
              <div id="client-authorization-pending" class={["mt-8"]}>
                <p class={["text-sm leading-6 text-ink-muted"]}>
                  Confirm that this code matches the one shown in your terminal:
                </p>
                <div
                  id="client-authorization-code"
                  class={[
                    "mt-4 border-2 border-strong bg-well px-4 py-5 text-center font-mono text-3xl font-bold tracking-[0.18em] text-ink"
                  ]}
                >
                  {@display_code}
                </div>

                <div class={["mt-6 border-y-2 border-rule py-5"]}>
                  <p class={["text-sm text-ink"]}>
                    <span class={["font-semibold"]}>{@authorization.client_name}</span>
                    will be able to:
                  </p>
                  <ul
                    id="client-authorization-scopes"
                    class={["mt-3 space-y-2 text-sm text-ink-muted"]}
                  >
                    <li class={["flex gap-2"]}>
                      <.icon name="hero-check" class={["mt-0.5 size-4 text-ink"]} />
                      Read and claim public security jobs
                    </li>
                    <li class={["flex gap-2"]}>
                      <.icon name="hero-check" class={["mt-0.5 size-4 text-ink"]} />
                      Submit reports and job results
                    </li>
                    <li class={["flex gap-2"]}>
                      <.icon name="hero-check" class={["mt-0.5 size-4 text-ink"]} />
                      Read and independently check findings
                    </li>
                  </ul>
                </div>

                <p class={["mt-5 text-xs leading-5 text-ink-faint"]}>
                  A revocable credential will be created for
                  <span class={["font-mono"]}>@{@current_scope.account.handle}</span>
                  and expire after 30 days.
                </p>

                <div class={["mt-6 grid gap-3 sm:grid-cols-2"]}>
                  <button
                    id="client-authorization-deny-button"
                    phx-click="deny"
                    class={[
                      "h-11 border-2 border-strong px-4 font-display text-sm uppercase tracking-[0.12em] text-ink transition hover:bg-well"
                    ]}
                  >
                    Deny
                  </button>
                  <button
                    id="client-authorization-approve-button"
                    phx-click="approve"
                    class={[
                      "clip-notch h-11 bg-btn px-4 font-display text-sm uppercase tracking-[0.12em] text-btn-fg transition hover:opacity-90"
                    ]}
                    phx-disable-with="Authorizing…"
                  >
                    Authorize client
                  </button>
                </div>
              </div>
          <% end %>
        </section>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
