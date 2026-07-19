defmodule TarakanWeb.ClientAuthorizationLive do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts.ClientAuthorizations

  @impl true
  def mount(%{"user_code" => user_code}, _session, socket) do
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
         |> put_flash(:info, "Connected. You can go back to the terminal.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:authorization, nil)
         |> put_flash(:error, "This login request expired or was already used.")}
    end
  end

  def handle_event("deny", _params, socket) do
    account = socket.assigns.current_scope.account

    case ClientAuthorizations.deny(socket.assigns.authorization, account) do
      {:ok, authorization} ->
        {:noreply,
         socket
         |> assign(:authorization, authorization)
         |> put_flash(:info, "Denied.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :authorization, nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page id="client-authorization-page" width={:compact}>
        <section class={[
          "border-2 border-strong bg-panel p-6 shadow-[8px_8px_0_0_var(--color-rule)] sm:p-8"
        ]}>
          <div class={["flex items-start gap-4"]}>
            <div class={[
              "flex size-11 shrink-0 items-center justify-center border-2 border-strong bg-signal text-ground"
            ]}>
              <.icon name="hero-command-line" class={["size-6"]} />
            </div>
            <div class={["min-w-0"]}>
              <h1 class={[
                "font-display text-2xl font-medium uppercase tracking-[0.04em] text-ink"
              ]}>
                Connect your terminal
              </h1>
              <p class={["mt-2 text-sm leading-6 text-ink-muted"]}>
                Approving lets the client claim jobs as @{@current_scope.account.handle}.
              </p>
            </div>
          </div>

          <%= cond do %>
            <% is_nil(@authorization) -> %>
              <div id="client-authorization-expired" class={["mt-8 border-2 border-rule p-5"]}>
                <p class={["text-sm text-ink"]}>
                  That code is invalid or expired. Run <code class="font-mono">tarakan login</code>
                  again.
                </p>
              </div>
            <% @authorization.status == "approved" -> %>
              <div
                id="client-authorization-approved"
                class={["mt-8 border-2 border-phosphor bg-ground p-5"]}
              >
                <p class={["text-sm font-semibold text-ink"]}>Connected.</p>
                <p class={["mt-1 text-sm text-ink-muted"]}>Back to your terminal.</p>
              </div>
            <% @authorization.status == "denied" -> %>
              <div id="client-authorization-denied" class={["mt-8 border-2 border-rule p-5"]}>
                <p class={["text-sm text-ink"]}>Denied. Nothing was granted.</p>
              </div>
            <% true -> %>
              <div id="client-authorization-pending" class={["mt-8"]}>
                <p class={["text-xs font-semibold text-ink-muted"]}>
                  Code
                </p>
                <div
                  id="client-authorization-code"
                  class={[
                    "mt-2 border-2 border-strong bg-ground px-4 py-3 font-mono text-2xl tracking-[0.2em] text-ink sm:text-3xl"
                  ]}
                >
                  {@display_code}
                </div>

                <p class={["mt-5 text-sm text-ink-muted"]}>
                  {@authorization.client_name} can claim jobs and submit reviews for
                  about 7 days. Revoke anytime in settings.
                </p>

                <div class={["mt-6 grid gap-3 sm:grid-cols-2"]}>
                  <button
                    id="client-authorization-deny-button"
                    phx-click="deny"
                    class={[
                      "flex h-12 items-center justify-center border-2 border-strong px-4 font-display text-sm uppercase tracking-[0.14em] text-ink transition hover:bg-ground"
                    ]}
                  >
                    Deny
                  </button>
                  <button
                    id="client-authorization-approve-button"
                    phx-click="approve"
                    class={[
                      "clip-notch flex h-12 items-center justify-center bg-btn px-4 font-display text-sm uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90"
                    ]}
                  >
                    Approve
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
