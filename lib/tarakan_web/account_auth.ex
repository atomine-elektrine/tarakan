defmodule TarakanWeb.AccountAuth do
  use TarakanWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Tarakan.Accounts
  alias Tarakan.Accounts.ApiCredentials
  alias Tarakan.Accounts.Scope

  # Make the remember me cookie valid for 60 days. This should match
  # the session validity setting in AccountToken.
  @max_cookie_age_in_days 60
  @remember_me_cookie "_tarakan_web_account_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax",
    secure: Application.compile_env(:tarakan, :secure_cookies, true)
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the account in.

  Redirects to the session's `:account_return_to` path
  or falls back to the `signed_in_path/1`.

  Always stamps a fresh `authenticated_at` so sudo-mode (recent auth) starts
  from this login. Session reissue uses `create_or_extend_session/3` directly
  and preserves the previous stamp.
  """
  def log_in_account(conn, account, params \\ %{}) do
    # Params may carry return_to from the login form (sudo reauth).
    conn = maybe_put_return_to_from_params(conn, params)
    account_return_to = get_session(conn, :account_return_to)

    # Explicit login / magic-link reauth always counts as recent authentication.
    account = %{account | authenticated_at: DateTime.utc_now(:second)}

    conn
    |> create_or_extend_session(account, params)
    |> delete_session(:account_return_to)
    |> redirect(to: account_return_to || signed_in_path(conn))
  end

  @doc """
  Path to the login page that returns the user to `return_to` after magic-link
  (or password) re-authentication. Used for sudo-mode gates.
  """
  def reauth_path(return_to) when is_binary(return_to) do
    path = TarakanWeb.SafeRedirect.local_path(return_to, "/")
    ~p"/accounts/log-in?#{[return_to: path]}"
  end

  def reauth_path(_), do: ~p"/accounts/log-in"

  defp maybe_put_return_to_from_params(conn, params) when is_map(params) do
    raw = params["return_to"] || params[:return_to]

    case raw do
      path when is_binary(path) and path != "" ->
        put_session(conn, :account_return_to, TarakanWeb.SafeRedirect.local_path(path, "/"))

      _ ->
        conn
    end
  end

  defp maybe_put_return_to_from_params(conn, _params), do: conn

  @doc """
  Logs the account out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_account(conn) do
    account_token = get_session(conn, :account_token)
    account_token && Accounts.delete_account_session_token(account_token)

    # live_socket_id is the account-scoped topic (see put_token_in_session/2), so
    # this drops every LiveView on the account — other tabs included.
    if live_socket_id = get_session(conn, :live_socket_id) do
      TarakanWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the account by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_account(conn, _opts) do
    with {token, conn} <- ensure_account_token(conn),
         {account, token_inserted_at} <- Accounts.get_account_by_session_token(token) do
      conn
      |> assign(
        :current_scope,
        Accounts.scope_for_account(account, authentication_method: :session)
      )
      |> maybe_reissue_account_session_token(account, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, nil)
    end
  end

  @doc """
  Authenticates an API request by its bearer token.

  Assigns `current_scope` when the token is valid; otherwise halts with 401.
  """
  def fetch_api_account(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, account, credential} <- ApiCredentials.authenticate(token) do
      scope =
        Accounts.scope_for_account(account,
          token_id: credential.id,
          token_scopes: credential.scopes,
          token_repository_id: credential.repository_id,
          authentication_method: :api_credential
        )

      assign(conn, :current_scope, scope)
    else
      _other ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "missing or invalid API token"})
        |> halt()
    end
  end

  defp ensure_account_token(conn) do
    if token = get_session(conn, :account_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        case Accounts.get_account_by_session_token(token) do
          {%{id: account_id}, _inserted_at} ->
            {token,
             conn
             |> put_token_in_session(token, account_id)
             |> put_session(:account_remember_me, true)}

          nil ->
            nil
        end
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_account_session_token(conn, account, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, account, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # Every login persists across browser restarts: the signed remember-me
  # cookie is always written, whichever way the account signed in (password,
  # magic link, or forge OAuth). Logging out deletes it.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, account, _params) do
    token = Accounts.generate_account_session_token(account)

    conn
    |> renew_session(account)
    |> put_token_in_session(token, account.id)
    |> write_remember_me_cookie(token)
  end

  # Do not renew session if the account is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, account) when conn.assigns.current_scope.account.id == account.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _account) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _account) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:account_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token, account_id) do
    conn
    |> put_session(:account_token, token)
    # Account-scoped so ban/password-change can disconnect every LiveView without
    # retaining plaintext session tokens in the database.
    |> put_session(:live_socket_id, Accounts.account_sessions_topic(account_id))
  end

  @doc """
  Disconnects LiveViews for an account (or each account id in a list).

  Accepts an account id, a list of account ids, or legacy token structs that
  carry `:account_id` (password-change / magic-link flows).
  """
  def disconnect_sessions(account_id) when is_integer(account_id) do
    disconnect_account_sessions(account_id)
  end

  def disconnect_sessions(account_ids) when is_list(account_ids) do
    account_ids
    |> Enum.flat_map(fn
      id when is_integer(id) -> [id]
      %{account_id: id} when is_integer(id) -> [id]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.each(&disconnect_account_sessions/1)
  end

  def disconnect_sessions(_other), do: :ok

  @doc "Disconnects every LiveView socket for `account_id`."
  def disconnect_account_sessions(account_id) when is_integer(account_id) do
    TarakanWeb.Endpoint.broadcast(Accounts.account_sessions_topic(account_id), "disconnect", %{})
  end

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on account_token, or nil if
      there's no account_token or no matching account.

    * `:require_authenticated` - Authenticates the account from the session,
      and assigns the current_scope to socket assigns based
      on account_token.
      Redirects to login page if there's no logged account.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule TarakanWeb.PageLive do
        use TarakanWeb, :live_view

        on_mount {TarakanWeb.AccountAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{TarakanWeb.AccountAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.account do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/accounts/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.account) do
      {:cont, socket}
    else
      return_to = session["account_return_to"] || ~p"/accounts/settings"

      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          "Confirm it's you with a magic link (sign-in older than 2 hours for sensitive settings)."
        )
        |> Phoenix.LiveView.redirect(to: reauth_path(return_to))

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        {account, _} =
          if account_token = session["account_token"] do
            Accounts.get_account_by_session_token(account_token)
          end || {nil, nil}

        Accounts.scope_for_account(account, authentication_method: :session)
      end)

    socket = Phoenix.Component.assign_new(socket, :client_ip, fn -> live_client_ip(socket) end)

    attach_authorization_invalidation(socket)
  end

  defp live_client_ip(socket) do
    peer =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _other -> nil
      end

    x_headers =
      case Phoenix.LiveView.get_connect_info(socket, :x_headers) do
        headers when is_list(headers) -> headers
        _other -> []
      end

    proxies = Application.get_env(:tarakan, :trusted_proxies, [])
    forwarded_headers = Application.get_env(:tarakan, :remote_ip_headers, ["x-forwarded-for"])

    cond do
      is_tuple(peer) and proxies != [] and TarakanWeb.Plugs.ClientIp.trusted_ip?(peer, proxies) ->
        forwarded_values =
          Enum.flat_map(x_headers, fn
            {name, value} ->
              if String.downcase(to_string(name)) in forwarded_headers, do: [value], else: []

            _other ->
              []
          end)

        case TarakanWeb.Plugs.ClientIp.client_ip_from_headers(forwarded_values, proxies) do
          ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
          nil -> peer |> :inet.ntoa() |> to_string()
        end

      is_tuple(peer) ->
        peer |> :inet.ntoa() |> to_string()

      true ->
        "unavailable"
    end
  rescue
    _error -> "unavailable"
  end

  defp attach_authorization_invalidation(
         %{
           assigns: %{current_scope: %Scope{account_id: account_id}},
           private: %{lifecycle: _lifecycle}
         } = socket
       )
       when is_integer(account_id) do
    if socket.assigns[:authorization_invalidation_attached] do
      socket
    else
      if Phoenix.LiveView.connected?(socket) do
        :ok = Accounts.subscribe_authorization(account_id)
      end

      socket
      |> Phoenix.Component.assign(:authorization_invalidation_attached, true)
      |> Phoenix.LiveView.attach_hook(
        :authorization_invalidation,
        :handle_info,
        fn
          {:authorization_changed, ^account_id}, socket ->
            {:halt, Phoenix.LiveView.push_navigate(socket, to: ~p"/")}

          _message, socket ->
            {:cont, socket}
        end
      )
    end
  end

  defp attach_authorization_invalidation(socket), do: socket

  @doc "Returns the path to redirect to after log in when no return_to is set."
  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the account to be authenticated.
  """
  def require_authenticated_account(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.account do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/accounts/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :account_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
