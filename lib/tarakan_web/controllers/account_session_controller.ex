defmodule TarakanWeb.AccountSessionController do
  use TarakanWeb, :controller

  alias Tarakan.Accounts
  alias TarakanWeb.AccountAuth
  alias TarakanWeb.BrowserRateLimit

  def create(conn, %{"_action" => "confirmed"} = params) do
    rate_limited_create(conn, params, "Account confirmed successfully.")
  end

  def create(conn, params) do
    rate_limited_create(conn, params, "Welcome back!")
  end

  defp rate_limited_create(conn, params, info) do
    account_params = Map.get(params, "account", %{})

    identifier =
      account_params["identifier"] || account_params["email"] || account_params["token"] ||
        "missing"

    remote_ip = remote_ip(conn)
    identifier_key = :crypto.hash(:sha256, identifier |> to_string() |> String.downcase())

    checks = [
      BrowserRateLimit.allowed?(:login_ip, remote_ip),
      BrowserRateLimit.allowed?(:login_pair, {remote_ip, identifier_key})
    ]

    if Enum.all?(checks) do
      create(conn, params, info)
    else
      conn
      |> put_flash(:error, "Invalid credentials or too many attempts. Try again later.")
      |> redirect(to: ~p"/accounts/log-in")
    end
  end

  # magic link login
  defp create(conn, %{"account" => %{"token" => token} = account_params}, info) do
    case Accounts.login_account_by_magic_link(token) do
      {:ok, {account, disconnect_ref}} ->
        AccountAuth.disconnect_sessions(disconnect_ref)

        conn
        |> put_flash(:info, info)
        |> AccountAuth.log_in_account(account, account_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/accounts/log-in")
    end
  end

  # handle/email + password login
  defp create(conn, %{"account" => account_params}, info) do
    identifier = Map.get(account_params, "identifier", "")
    password = Map.get(account_params, "password", "")

    if account = Accounts.get_account_by_identifier_and_password(identifier, password) do
      conn
      |> put_flash(:info, info)
      |> AccountAuth.log_in_account(account, account_params)
    else
      # Do not disclose whether the handle or email is registered.
      conn
      |> put_flash(:error, "Invalid handle, email, or password")
      |> put_flash(:identifier, String.slice(identifier, 0, 160))
      |> redirect(to: ~p"/accounts/log-in")
    end
  end

  def update_password(conn, %{"account" => account_params}) do
    account = conn.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)
    {:ok, {account, disconnect_ref}} = Accounts.update_account_password(account, account_params)

    # disconnect all existing LiveViews with old sessions
    AccountAuth.disconnect_sessions(disconnect_ref)

    conn
    |> put_session(:account_return_to, ~p"/accounts/settings")
    |> put_flash(:info, "Password updated successfully!")
    |> AccountAuth.log_in_account(account)
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> AccountAuth.log_out_account()
  end

  defp remote_ip(conn), do: TarakanWeb.Plugs.ClientIp.remote_ip_string(conn)
end
