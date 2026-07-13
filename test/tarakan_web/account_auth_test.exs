defmodule TarakanWeb.AccountAuthTest do
  use TarakanWeb.ConnCase, async: true

  alias Phoenix.LiveView
  alias Tarakan.Accounts
  alias Tarakan.Accounts.ApiCredentials
  alias Tarakan.Accounts.Scope
  alias TarakanWeb.AccountAuth

  import Tarakan.AccountsFixtures

  @remember_me_cookie "_tarakan_web_account_remember_me"
  @remember_me_cookie_max_age 60 * 60 * 24 * 60

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, TarakanWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{account: %{account_fixture() | authenticated_at: DateTime.utc_now(:second)}, conn: conn}
  end

  describe "log_in_account/3" do
    test "stores the account token in the session", %{conn: conn, account: account} do
      conn = AccountAuth.log_in_account(conn, account)
      assert token = get_session(conn, :account_token)
      assert get_session(conn, :live_socket_id) == Accounts.account_sessions_topic(account.id)
      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_account_by_session_token(token)
    end

    test "clears everything previously stored in the session", %{conn: conn, account: account} do
      conn = conn |> put_session(:to_be_removed, "value") |> AccountAuth.log_in_account(account)
      refute get_session(conn, :to_be_removed)
    end

    test "keeps session when re-authenticating", %{conn: conn, account: account} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_account(account))
        |> put_session(:to_be_removed, "value")
        |> AccountAuth.log_in_account(account)

      assert get_session(conn, :to_be_removed)
    end

    test "clears session when account does not match when re-authenticating", %{
      conn: conn,
      account: account
    } do
      other_account = account_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_account(other_account))
        |> put_session(:to_be_removed, "value")
        |> AccountAuth.log_in_account(account)

      refute get_session(conn, :to_be_removed)
    end

    test "redirects to the configured path", %{conn: conn, account: account} do
      conn =
        conn |> put_session(:account_return_to, "/hello") |> AccountAuth.log_in_account(account)

      assert redirected_to(conn) == "/hello"
    end

    test "writes a cookie if remember_me is configured", %{conn: conn, account: account} do
      conn =
        conn |> fetch_cookies() |> AccountAuth.log_in_account(account, %{"remember_me" => "true"})

      assert get_session(conn, :account_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :account_remember_me) == true

      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :account_token)
      assert max_age == @remember_me_cookie_max_age
    end

    test "writes the persistent cookie without remember_me params (OAuth logins)", %{
      conn: conn,
      account: account
    } do
      conn = conn |> fetch_cookies() |> AccountAuth.log_in_account(account)

      assert get_session(conn, :account_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :account_remember_me) == true
      assert %{max_age: @remember_me_cookie_max_age} = conn.resp_cookies[@remember_me_cookie]
    end

    test "redirects home when account is already logged in and no return_to is set", %{
      conn: conn,
      account: account
    } do
      conn =
        conn
        |> assign(:current_scope, Scope.for_account(account))
        |> AccountAuth.log_in_account(account)

      assert redirected_to(conn) == ~p"/"
    end

    test "writes a cookie if remember_me was set in previous session", %{
      conn: conn,
      account: account
    } do
      conn =
        conn |> fetch_cookies() |> AccountAuth.log_in_account(account, %{"remember_me" => "true"})

      assert get_session(conn, :account_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :account_remember_me) == true

      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, TarakanWeb.Endpoint.config(:secret_key_base))
        |> fetch_cookies()
        |> init_test_session(%{account_remember_me: true})

      # the conn is already logged in and has the remember_me cookie set,
      # now we log in again and even without explicitly setting remember_me,
      # the cookie should be set again
      conn = conn |> AccountAuth.log_in_account(account, %{})
      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :account_token)
      assert max_age == @remember_me_cookie_max_age
      assert get_session(conn, :account_remember_me) == true
    end
  end

  describe "logout_account/1" do
    test "erases session and cookies", %{conn: conn, account: account} do
      account_token = Accounts.generate_account_session_token(account)

      conn =
        conn
        |> put_session(:account_token, account_token)
        |> put_req_cookie(@remember_me_cookie, account_token)
        |> fetch_cookies()
        |> AccountAuth.log_out_account()

      refute get_session(conn, :account_token)
      refute conn.cookies[@remember_me_cookie]
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
      refute Accounts.get_account_by_session_token(account_token)
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      live_socket_id = "accounts_sessions:abcdef-token"
      TarakanWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:live_socket_id, live_socket_id)
      |> AccountAuth.log_out_account()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if account is already logged out", %{conn: conn} do
      conn = conn |> fetch_cookies() |> AccountAuth.log_out_account()
      refute get_session(conn, :account_token)
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "fetch_current_scope_for_account/2" do
    test "authenticates account from session", %{conn: conn, account: account} do
      account_token = Accounts.generate_account_session_token(account)

      conn =
        conn
        |> put_session(:account_token, account_token)
        |> AccountAuth.fetch_current_scope_for_account([])

      assert conn.assigns.current_scope.account.id == account.id
      assert conn.assigns.current_scope.account.authenticated_at == account.authenticated_at
      assert get_session(conn, :account_token) == account_token
    end

    test "authenticates account from cookies", %{conn: conn, account: account} do
      logged_in_conn =
        conn |> fetch_cookies() |> AccountAuth.log_in_account(account, %{"remember_me" => "true"})

      account_token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      conn =
        conn
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> AccountAuth.fetch_current_scope_for_account([])

      assert conn.assigns.current_scope.account.id == account.id
      assert conn.assigns.current_scope.account.authenticated_at == account.authenticated_at
      assert get_session(conn, :account_token) == account_token
      assert get_session(conn, :account_remember_me)

      assert get_session(conn, :live_socket_id) == Accounts.account_sessions_topic(account.id)
    end

    test "does not authenticate if data is missing", %{conn: conn, account: account} do
      _ = Accounts.generate_account_session_token(account)
      conn = AccountAuth.fetch_current_scope_for_account(conn, [])
      refute get_session(conn, :account_token)
      refute conn.assigns.current_scope
    end

    test "reissues a new token after a few days and refreshes cookie", %{
      conn: conn,
      account: account
    } do
      logged_in_conn =
        conn |> fetch_cookies() |> AccountAuth.log_in_account(account, %{"remember_me" => "true"})

      token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      offset_account_token(token, -10, :day)
      {account, _} = Accounts.get_account_by_session_token(token)

      conn =
        conn
        |> put_session(:account_token, token)
        |> put_session(:account_remember_me, true)
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> AccountAuth.fetch_current_scope_for_account([])

      assert conn.assigns.current_scope.account.id == account.id
      assert conn.assigns.current_scope.account.authenticated_at == account.authenticated_at
      assert new_token = get_session(conn, :account_token)
      assert new_token != token
      assert %{value: new_signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert new_signed_token != signed_token
      assert max_age == @remember_me_cookie_max_age
    end
  end

  describe "fetch_api_account/2" do
    test "assigns credential scopes, repository boundary, and authentication method", %{
      conn: conn,
      account: account
    } do
      repository = github_repository_fixture(account)

      assert {:ok, token, credential} =
               ApiCredentials.create(account, %{
                 name: "repository worker",
                 scopes: ["tasks:read", "tasks:claim"],
                 repository_id: repository.id
               })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AccountAuth.fetch_api_account([])

      scope = conn.assigns.current_scope
      assert scope.account_id == account.id
      assert scope.token_id == credential.id
      assert scope.token_scopes == MapSet.new(["tasks:read", "tasks:claim"])
      assert scope.token_repository_id == repository.id
      assert scope.authentication_method == :api_credential
    end

    test "rejects malformed and revoked credentials", %{conn: conn, account: account} do
      invalid =
        conn
        |> put_req_header("authorization", "Bearer not-a-token")
        |> AccountAuth.fetch_api_account([])

      assert invalid.halted
      assert invalid.status == 401

      assert {:ok, token, credential} = ApiCredentials.create(account, %{name: "revoked"})
      assert {:ok, _credential} = ApiCredentials.revoke(account, credential.id)

      revoked =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{token}")
        |> AccountAuth.fetch_api_account([])

      assert revoked.halted
      assert revoked.status == 401
    end
  end

  describe "on_mount :mount_current_scope" do
    setup %{conn: conn} do
      %{conn: AccountAuth.fetch_current_scope_for_account(conn, [])}
    end

    test "assigns current_scope based on a valid account_token", %{conn: conn, account: account} do
      account_token = Accounts.generate_account_session_token(account)
      session = conn |> put_session(:account_token, account_token) |> get_session()

      {:cont, updated_socket} =
        AccountAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.account.id == account.id
    end

    test "assigns nil to current_scope assign if there isn't a valid account_token", %{conn: conn} do
      account_token = "invalid_token"
      session = conn |> put_session(:account_token, account_token) |> get_session()

      {:cont, updated_socket} =
        AccountAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end

    test "assigns nil to current_scope assign if there isn't a account_token", %{conn: conn} do
      session = conn |> get_session()

      {:cont, updated_socket} =
        AccountAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_authenticated" do
    test "authenticates current_scope based on a valid account_token", %{
      conn: conn,
      account: account
    } do
      account_token = Accounts.generate_account_session_token(account)
      session = conn |> put_session(:account_token, account_token) |> get_session()

      {:cont, updated_socket} =
        AccountAuth.on_mount(:require_authenticated, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.account.id == account.id
    end

    test "redirects to login page if there isn't a valid account_token", %{conn: conn} do
      account_token = "invalid_token"
      session = conn |> put_session(:account_token, account_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: TarakanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = AccountAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects to login page if there isn't a account_token", %{conn: conn} do
      session = conn |> get_session()

      socket = %LiveView.Socket{
        endpoint: TarakanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = AccountAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_sudo_mode" do
    test "allows accounts that have authenticated in the last 10 minutes", %{
      conn: conn,
      account: account
    } do
      account_token = Accounts.generate_account_session_token(account)
      session = conn |> put_session(:account_token, account_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: TarakanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:cont, _updated_socket} =
               AccountAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end

    test "redirects when authentication is too old", %{conn: conn, account: account} do
      nine_hours_ago = DateTime.utc_now(:second) |> DateTime.add(-9 * 60, :minute)
      account = %{account | authenticated_at: nine_hours_ago}
      account_token = Accounts.generate_account_session_token(account)
      {account, token_inserted_at} = Accounts.get_account_by_session_token(account_token)
      assert DateTime.compare(token_inserted_at, account.authenticated_at) == :gt
      session = conn |> put_session(:account_token, account_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: TarakanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _updated_socket} =
               AccountAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end
  end

  describe "require_authenticated_account/2" do
    setup %{conn: conn} do
      %{conn: AccountAuth.fetch_current_scope_for_account(conn, [])}
    end

    test "redirects if account is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> AccountAuth.require_authenticated_account([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/accounts/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> AccountAuth.require_authenticated_account([])

      assert halted_conn.halted
      assert get_session(halted_conn, :account_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> AccountAuth.require_authenticated_account([])

      assert halted_conn.halted
      assert get_session(halted_conn, :account_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> AccountAuth.require_authenticated_account([])

      assert halted_conn.halted
      refute get_session(halted_conn, :account_return_to)
    end

    test "does not redirect if account is authenticated", %{conn: conn, account: account} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_account(account))
        |> AccountAuth.require_authenticated_account([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "disconnect_sessions/1" do
    test "broadcasts disconnect messages for each account id" do
      TarakanWeb.Endpoint.subscribe(Accounts.account_sessions_topic(11))
      TarakanWeb.Endpoint.subscribe(Accounts.account_sessions_topic(22))

      AccountAuth.disconnect_sessions([11, %{account_id: 22}])

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "accounts_sessions:11"
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "accounts_sessions:22"
      }
    end
  end
end
