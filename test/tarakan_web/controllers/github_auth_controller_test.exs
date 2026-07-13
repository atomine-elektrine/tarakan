defmodule TarakanWeb.GitHubAuthControllerTest do
  use TarakanWeb.ConnCase

  alias Tarakan.Accounts

  test "starts GitHub authorization with state and PKCE", %{conn: conn} do
    conn = get(conn, ~p"/auth/github?return_to=/")

    location = redirected_to(conn, 302)
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert String.starts_with?(location, "https://github.com/login/oauth/authorize?")
    assert query["client_id"] == "test-client-id"
    assert query["code_challenge_method"] == "S256"
    assert query["code_challenge"]
    assert query["state"] == get_session(conn, :github_oauth_state)
    assert get_session(conn, :github_oauth_verifier)
  end

  test "creates a session after GitHub authorizes the user", %{conn: conn} do
    authorization_conn = get(conn, ~p"/auth/github?return_to=/")
    state = get_session(authorization_conn, :github_oauth_state)

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(callback_conn) == "/"
    token = get_session(callback_conn, :account_token)
    assert {account, _inserted_at} = Accounts.get_account_by_session_token(token)
    assert account.handle == "tarakantester"
    assert is_nil(account.display_name)
    assert is_nil(account.email)
    refute get_session(callback_conn, :github_oauth_state)
    refute get_session(callback_conn, :github_oauth_verifier)

    assert Tarakan.Repo.get_by!(Tarakan.Accounts.Identity,
             account_id: account.id,
             provider: "github"
           )
  end

  test "rejects a callback with an invalid state", %{conn: conn} do
    authorization_conn = get(conn, ~p"/auth/github")

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=wrong-state")

    assert redirected_to(callback_conn) == "/"
    refute get_session(callback_conn, :account_token)
  end

  test "links GitHub to the signed-in Tarakan account", %{conn: conn} do
    account = account_fixture()

    authorization_conn =
      conn
      |> log_in_account(account)
      |> get(~p"/auth/github?return_to=/accounts/settings")

    state = get_session(authorization_conn, :github_oauth_state)

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(callback_conn) == "/accounts/settings"
    token = get_session(callback_conn, :account_token)
    assert {linked_account, _inserted_at} = Accounts.get_account_by_session_token(token)
    assert linked_account.id == account.id

    assert Tarakan.Repo.get_by!(Tarakan.Accounts.Identity,
             account_id: account.id,
             provider: "github"
           )
  end

  test "refuses to link an identity from a stale signed-in session", %{conn: conn} do
    account = account_fixture()
    stale_at = DateTime.add(DateTime.utc_now(:second), -9 * 60, :minute)

    authorization_conn =
      conn
      |> log_in_account(account, token_authenticated_at: stale_at)
      |> get(~p"/auth/github?return_to=/accounts/settings")

    state = get_session(authorization_conn, :github_oauth_state)

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(callback_conn) == "/accounts/settings"

    refute Tarakan.Repo.get_by(Tarakan.Accounts.Identity,
             account_id: account.id,
             provider: "github"
           )
  end

  test "does not retain a malicious return path in the OAuth session" do
    for return_to <- ["//attacker.example", "/\\attacker.example", "/%255cattacker.example"] do
      query = URI.encode_query(%{"return_to" => return_to})
      authorization_conn = get(build_conn(), "/auth/github?#{query}")

      assert get_session(authorization_conn, :github_oauth_return_to) == "/"
    end
  end

  test "signs the current user out", %{conn: conn} do
    conn = conn |> log_in_account(account_fixture()) |> delete(~p"/accounts/log-out")

    assert redirected_to(conn) == "/"
    refute get_session(conn, :account_token)
  end
end
