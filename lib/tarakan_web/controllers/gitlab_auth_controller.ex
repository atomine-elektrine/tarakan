defmodule TarakanWeb.GitLabAuthController do
  use TarakanWeb, :controller

  alias Tarakan.Accounts
  alias Tarakan.GitLab.OAuth
  alias TarakanWeb.AccountAuth
  alias TarakanWeb.SafeRedirect

  def request(conn, params) do
    return_to = safe_return_to(params["return_to"])

    if OAuth.configured?() do
      state = OAuth.generate_state()
      {verifier, challenge} = OAuth.generate_pkce()
      redirect_uri = url(~p"/auth/gitlab/callback")

      conn
      |> put_session(:gitlab_oauth_state, state)
      |> put_session(:gitlab_oauth_verifier, verifier)
      |> put_session(:gitlab_oauth_return_to, return_to)
      |> redirect(external: OAuth.authorize_url(state, challenge, redirect_uri))
    else
      conn
      |> put_flash(:error, "GitLab login has not been configured yet.")
      |> redirect(to: return_to)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :gitlab_oauth_state)
    verifier = get_session(conn, :gitlab_oauth_verifier)
    return_to = safe_return_to(get_session(conn, :gitlab_oauth_return_to))
    redirect_uri = url(~p"/auth/gitlab/callback")
    current_account = conn.assigns.current_scope && conn.assigns.current_scope.account

    with true <- OAuth.valid_state?(expected_state, state),
         true <- is_binary(verifier),
         :ok <- authorize_identity_link(current_account),
         {:ok, token} <- OAuth.exchange_code(code, verifier, redirect_uri),
         {:ok, profile} <- OAuth.fetch_user(token),
         {:ok, account} <- Accounts.upsert_external_identity(:gitlab, profile, current_account),
         true <- Accounts.access_allowed?(account) do
      conn
      |> clear_oauth_session()
      |> put_session(:account_return_to, return_to)
      |> put_flash(:info, "Signed in as @#{account.handle}.")
      |> AccountAuth.log_in_account(account)
    else
      _error -> authorization_failed(conn, return_to)
    end
  end

  def callback(conn, _params) do
    authorization_failed(conn, safe_return_to(get_session(conn, :gitlab_oauth_return_to)))
  end

  defp authorization_failed(conn, return_to) do
    conn
    |> clear_oauth_session()
    |> put_flash(:error, "GitLab authentication failed. Please try again.")
    |> redirect(to: return_to)
  end

  defp clear_oauth_session(conn) do
    conn
    |> delete_session(:gitlab_oauth_state)
    |> delete_session(:gitlab_oauth_verifier)
    |> delete_session(:gitlab_oauth_return_to)
  end

  defp safe_return_to(path) when is_binary(path) do
    SafeRedirect.local_path(path)
  end

  defp safe_return_to(_path), do: "/"

  defp authorize_identity_link(nil), do: :ok

  defp authorize_identity_link(account) do
    if Accounts.sudo_mode?(account), do: :ok, else: {:error, :recent_authentication_required}
  end
end
