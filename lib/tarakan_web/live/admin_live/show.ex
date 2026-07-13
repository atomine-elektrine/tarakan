defmodule TarakanWeb.AdminLive.Show do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts
  alias Tarakan.Accounts.Account
  alias Tarakan.Policy
  alias TarakanWeb.AccountAuth

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    return_to = ~p"/admin/accounts/#{id}"

    cond do
      not Policy.allowed?(scope, :administer) ->
        {:ok, unauthorized(socket)}

      not Accounts.sudo_mode?(scope.account) ->
        {:ok,
         socket
         |> put_flash(:error, "Confirm it's you before changing account authority.")
         |> redirect(to: AccountAuth.reauth_path(return_to))}

      true ->
        case Accounts.get_account_for_admin(scope, id) do
          {:ok, account} -> {:ok, assign_account(socket, account)}
          {:error, _reason} -> {:ok, unauthorized(socket)}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"authorization" => params}, socket) do
    form =
      socket.assigns.account
      |> Account.authorization_changeset(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :authorization)

    {:noreply, assign(socket, :authorization_form, form)}
  end

  def handle_event("save", %{"authorization" => params}, socket) do
    case Accounts.update_authorization(
           socket.assigns.current_scope,
           socket.assigns.account,
           params
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign_account(account)
         |> put_flash(:info, "Authorization updated for @#{account.handle}.")}

      {:error, :last_admin} ->
        {:noreply,
         socket
         |> assign_invalid_form(params)
         |> put_flash(:error, "The last active administrator cannot be demoted or restricted.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :authorization_form, to_form(changeset, as: :authorization))}

      {:error, _reason} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp assign_account(socket, account) do
    socket
    |> assign(:page_title, "Manage @#{account.handle}")
    |> assign(:account, account)
    |> assign(
      :authorization_form,
      to_form(Account.authorization_changeset(account, %{}), as: :authorization)
    )
  end

  defp assign_invalid_form(socket, params) do
    changeset =
      socket.assigns.account
      |> Account.authorization_changeset(params)
      |> Ecto.Changeset.add_error(:platform_role, "must leave at least one active administrator")

    assign(socket, :authorization_form, to_form(changeset, as: :authorization))
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Administrator access is required.")
    |> redirect(to: ~p"/")
  end
end
