defmodule TarakanWeb.AccountLive.Registration do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts
  alias Tarakan.Accounts.Account

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:form} class={["py-14 sm:py-20"]}>
        <div class="text-center">
          <.header>
            Join Tarakan
            <:subtitle>
              Fastest path: GitHub. Already here?
              <.link navigate={~p"/accounts/log-in"} class="font-semibold text-signal hover:underline">
                Log in
              </.link>
            </:subtitle>
          </.header>
        </div>

        <div class="mt-6 space-y-3">
          <.link
            id="github-register-button"
            href={~p"/auth/github?return_to=/"}
            class="clip-notch flex h-12 w-full items-center justify-center bg-btn px-4 font-display text-sm uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90"
          >
            Continue with GitHub
          </.link>
          <.link
            id="gitlab-register-button"
            href={~p"/auth/gitlab?return_to=/"}
            class="flex h-12 w-full items-center justify-center border-2 border-strong px-4 font-display text-sm uppercase tracking-[0.14em] text-ink transition hover:bg-panel"
          >
            Continue with GitLab
          </.link>
        </div>

        <details class="mt-6 group border-2 border-rule">
          <summary class="cursor-pointer px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-faint transition hover:text-ink">
            Prefer email instead
          </summary>
          <.form
            for={@form}
            id="registration_form"
            phx-submit="save"
            phx-change="validate"
            class="space-y-4 border-t-2 border-rule bg-panel p-6"
          >
            <.input
              field={@form[:handle]}
              type="text"
              label="Handle"
              autocomplete="username"
              spellcheck="false"
              placeholder="signalghost"
              required
            />
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              spellcheck="false"
              required
            />

            <button
              type="submit"
              phx-disable-with="Creating account..."
              class="clip-notch inline-flex h-11 w-full items-center justify-center bg-btn px-4 font-display text-sm uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90 focus:outline-none focus:ring-2 focus:ring-phosphor"
            >
              Email me a link
            </button>
          </.form>
        </details>

        <.form
          for={@login_form}
          id="registration_login_form"
          action={~p"/accounts/log-in"}
          phx-trigger-action={@trigger_login}
          class={["hidden"]}
        >
          <input type="hidden" name={@login_form[:token].name} value={@login_form[:token].value} />
          <input type="hidden" name={@login_form[:remember_me].name} value="true" />
        </.form>
      </Layouts.page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{account: account}}} = socket)
      when not is_nil(account) do
    {:ok, redirect(socket, to: TarakanWeb.AccountAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_account_registration(%Account{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign_form(changeset)
     |> assign(:login_form, to_form(%{"token" => ""}, as: "account"))
     |> assign(:trigger_login, false), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"account" => account_params}, socket) do
    if TarakanWeb.BrowserRateLimit.allowed?(:registration_ip, socket.assigns.client_ip) do
      register_account(socket, account_params)
    else
      registration_limited(socket)
    end
  end

  def handle_event("validate", %{"account" => account_params}, socket) do
    changeset =
      Accounts.change_account_registration(%Account{}, account_params, validate_unique: false)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # New accounts establish their first session immediately. Existing credentials
  # keep the generic email outcome so the form does not disclose account details.
  defp register_account(socket, account_params) do
    case Accounts.request_registration(account_params, &url(~p"/accounts/log-in/#{&1}")) do
      {:ok, {:created, token}} ->
        {:noreply,
         socket
         |> assign(:login_form, to_form(%{"token" => token}, as: "account"))
         |> assign(:trigger_login, true)}

      {:ok, :accepted} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "If an account matches those details, a sign-in link will arrive shortly."
         )
         |> push_navigate(to: ~p"/accounts/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp registration_limited(socket) do
    {:noreply,
     put_flash(socket, :error, "Too many account attempts from this network. Try again later.")}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "account")
    assign(socket, form: form)
  end
end
