defmodule TarakanWeb.AdminLive.Index do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts
  alias Tarakan.Policy
  alias TarakanWeb.AccountAuth

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    cond do
      not Policy.allowed?(scope, :administer) ->
        {:ok, unauthorized(socket)}

      not Accounts.sudo_mode?(scope.account) ->
        {:ok,
         socket
         |> put_flash(:error, "Confirm it's you before opening platform administration.")
         |> redirect(to: AccountAuth.reauth_path(~p"/admin"))}

      true ->
        with {:ok, accounts} <- Accounts.list_accounts_for_admin(scope),
             {:ok, summary} <- Accounts.account_admin_summary(scope) do
          {:ok,
           socket
           |> assign(:page_title, "Platform administration")
           |> assign(:summary, summary)
           |> assign(:account_count, length(accounts))
           |> assign(:filter_form, to_form(%{"query" => ""}, as: :filters))
           |> stream(:accounts, accounts)}
        else
          {:error, _reason} -> {:ok, unauthorized(socket)}
        end
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => %{"query" => query}}, socket) do
    case Accounts.list_accounts_for_admin(socket.assigns.current_scope, query) do
      {:ok, accounts} ->
        {:noreply,
         socket
         |> assign(:account_count, length(accounts))
         |> assign(:filter_form, to_form(%{"query" => query}, as: :filters))
         |> stream(:accounts, accounts, reset: true)}

      {:error, _reason} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Administrator access is required.")
    |> redirect(to: ~p"/")
  end
end
