defmodule TarakanWeb.AccountLive.Confirmation do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:form}>
        <div class="text-center">
          <.header>Welcome {@account.email}</.header>
        </div>

        <.form
          for={@form}
          id="login_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/accounts/log-in"}
          phx-trigger-action={@trigger_submit}
          class="space-y-3"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <input :if={@return_to} type="hidden" name="account[return_to]" value={@return_to} />
          <.input
            field={@form[:remember_me]}
            type="checkbox"
            label="Stay logged in on this device"
            checked
          />
          <button
            phx-disable-with="Logging in..."
            class="clip-notch inline-flex h-11 w-full items-center justify-center bg-btn px-4 font-display text-sm uppercase tracking-[0.14em] text-btn-fg transition hover:opacity-90"
          >
            Log in
          </button>
        </.form>
      </Layouts.page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token} = params, _session, socket) do
    return_to =
      case params do
        %{"return_to" => path} when is_binary(path) ->
          TarakanWeb.SafeRedirect.local_path(path, nil)

        _ ->
          nil
      end

    if account = Accounts.get_account_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "account")

      {:ok,
       assign(socket,
         account: account,
         form: form,
         trigger_submit: false,
         return_to: return_to
       ), temporary_assigns: [form: nil]}
    else
      next =
        if return_to,
          do: ~p"/accounts/log-in?#{[return_to: return_to]}",
          else: ~p"/accounts/log-in"

      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: next)}
    end
  end

  @impl true
  def handle_event("submit", %{"account" => params}, socket) do
    params =
      if socket.assigns.return_to,
        do: Map.put(params, "return_to", socket.assigns.return_to),
        else: params

    {:noreply, assign(socket, form: to_form(params, as: "account"), trigger_submit: true)}
  end
end
