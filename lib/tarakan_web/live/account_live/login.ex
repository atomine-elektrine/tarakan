defmodule TarakanWeb.AccountLive.Login do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:form} class={["space-y-5"]}>
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle>
              <%= if @current_scope && @current_scope.account do %>
                Confirm it's you, or connect another host.
              <% else %>
                One click. No password required.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div
          :if={local_mail_adapter?()}
          class="flex gap-3 border-2 border-rule bg-panel p-4 text-sm text-ink-muted"
        >
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <div class="space-y-3">
          <.link
            id="github-login-button"
            href={~p"/auth/github?#{[return_to: @provider_return_to]}"}
            class="clip-notch flex h-12 w-full items-center justify-center bg-btn px-4 font-display text-sm uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90"
          >
            Continue with GitHub
          </.link>
          <.link
            id="gitlab-login-button"
            href={~p"/auth/gitlab?#{[return_to: @provider_return_to]}"}
            class="flex h-12 w-full items-center justify-center border-2 border-strong px-4 font-display text-sm uppercase tracking-[0.14em] text-ink transition hover:bg-panel"
          >
            Continue with GitLab
          </.link>
        </div>

        <div class="flex items-center gap-3 py-1 font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
          <span class="h-px flex-1 bg-rule"></span>email<span class="h-px flex-1 bg-rule"></span>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/accounts/log-in"}
          phx-submit="submit_magic"
          class="space-y-3 border-2 border-strong bg-panel p-6"
        >
          <input :if={@return_to} type="hidden" name="account[return_to]" value={@return_to} />
          <.input
            readonly={!!(@current_scope && @current_scope.account)}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <button class="clip-notch inline-flex h-11 w-full items-center justify-center bg-btn px-4 font-display text-sm uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90">
            Email me a login link
          </button>
        </.form>

        <details class="group border-2 border-rule">
          <summary class="flex cursor-pointer items-center justify-between px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-faint transition hover:text-ink">
            Use a password instead
            <.icon
              name="hero-chevron-down"
              class="size-4 transition-transform group-open:rotate-180"
            />
          </summary>
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/accounts/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-3 border-t-2 border-rule bg-panel p-6"
          >
            <input :if={@return_to} type="hidden" name="account[return_to]" value={@return_to} />
            <.input
              readonly={!!(@current_scope && @current_scope.account)}
              field={f[:identifier]}
              type="text"
              label="Handle or email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <button class="clip-notch inline-flex h-11 w-full items-center justify-center bg-btn px-4 font-display text-sm uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90">
              Log in
            </button>
          </.form>
        </details>
      </Layouts.page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, session, socket) do
    account = get_in(socket.assigns, [:current_scope, Access.key(:account)])

    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        (account && account.email)

    identifier =
      Phoenix.Flash.get(socket.assigns.flash, :identifier) ||
        (account && account.handle)

    form = to_form(%{"email" => email, "identifier" => identifier}, as: "account")

    return_to =
      case params["return_to"] || session["account_return_to"] do
        path when is_binary(path) -> TarakanWeb.SafeRedirect.local_path(path, nil)
        _other -> nil
      end

    provider_return_to = return_to || if(account, do: ~p"/accounts/settings", else: ~p"/")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       return_to: return_to,
       provider_return_to: provider_return_to
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"account" => %{"email" => email} = params}, socket) do
    email_key = :crypto.hash(:sha256, email |> String.trim() |> String.downcase())

    allowed? =
      TarakanWeb.BrowserRateLimit.allowed?(:magic_ip, socket.assigns.client_ip) and
        TarakanWeb.BrowserRateLimit.allowed?(:magic_email, email_key)

    return_to =
      case params["return_to"] || socket.assigns.return_to do
        path when is_binary(path) and path != "" ->
          TarakanWeb.SafeRedirect.local_path(path, nil)

        _ ->
          nil
      end

    if allowed? do
      account = Accounts.get_account_by_email(email)

      if account && Accounts.access_allowed?(account) do
        Accounts.deliver_login_instructions(account, fn token ->
          if return_to do
            url(~p"/accounts/log-in/#{token}?#{[return_to: return_to]}")
          else
            url(~p"/accounts/log-in/#{token}")
          end
        end)
      end
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    next =
      if return_to,
        do: ~p"/accounts/log-in?#{[return_to: return_to]}",
        else: ~p"/accounts/log-in"

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: next)}
  end

  defp local_mail_adapter? do
    Application.get_env(:tarakan, Tarakan.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
