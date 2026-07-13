defmodule TarakanWeb.GitLabAuthControllerTest do
  use TarakanWeb.ConnCase

  alias Tarakan.Accounts

  test "starts GitLab authorization with state, PKCE, and read_user", %{conn: conn} do
    conn = get(conn, ~p"/auth/gitlab?return_to=/")

    location = redirected_to(conn, 302)
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert String.starts_with?(location, "https://gitlab.com/oauth/authorize?")
    assert query["client_id"] == "test-gitlab-client-id"
    assert query["response_type"] == "code"
    assert query["scope"] == "read_user"
    assert query["code_challenge_method"] == "S256"
    assert query["code_challenge"]
    assert query["state"] == get_session(conn, :gitlab_oauth_state)
    assert get_session(conn, :gitlab_oauth_verifier)
  end

  test "creates an account and session without native registration", %{conn: conn} do
    authorization_conn = get(conn, ~p"/auth/gitlab?return_to=/")
    state = get_session(authorization_conn, :gitlab_oauth_state)

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/gitlab/callback?code=valid-gitlab-code&state=#{state}")

    assert redirected_to(callback_conn) == "/"
    token = get_session(callback_conn, :account_token)
    assert {account, _inserted_at} = Accounts.get_account_by_session_token(token)
    assert account.handle == "gitlabsignal"
    assert is_nil(account.display_name)
    assert is_nil(account.email)
    refute get_session(callback_conn, :gitlab_oauth_state)
    refute get_session(callback_conn, :gitlab_oauth_verifier)

    assert Tarakan.Repo.get_by!(Tarakan.Accounts.Identity,
             account_id: account.id,
             provider: "gitlab",
             provider_uid: "24680"
           )
  end

  test "rejects a callback with an invalid state", %{conn: conn} do
    authorization_conn = get(conn, ~p"/auth/gitlab")

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/gitlab/callback?code=valid-gitlab-code&state=wrong-state")

    assert redirected_to(callback_conn) == "/"
    refute get_session(callback_conn, :account_token)
  end

  test "links GitLab to the signed-in Tarakan account", %{conn: conn} do
    account = account_fixture()

    authorization_conn =
      conn
      |> log_in_account(account)
      |> get(~p"/auth/gitlab?return_to=/accounts/settings")

    state = get_session(authorization_conn, :gitlab_oauth_state)

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/gitlab/callback?code=valid-gitlab-code&state=#{state}")

    assert redirected_to(callback_conn) == "/accounts/settings"
    token = get_session(callback_conn, :account_token)
    assert {linked_account, _inserted_at} = Accounts.get_account_by_session_token(token)
    assert linked_account.id == account.id

    assert Tarakan.Repo.get_by!(Tarakan.Accounts.Identity,
             account_id: account.id,
             provider: "gitlab"
           )
  end

  test "refuses to link an identity from a stale signed-in session", %{conn: conn} do
    account = account_fixture()
    stale_at = DateTime.add(DateTime.utc_now(:second), -9 * 60, :minute)

    authorization_conn =
      conn
      |> log_in_account(account, token_authenticated_at: stale_at)
      |> get(~p"/auth/gitlab?return_to=/accounts/settings")

    state = get_session(authorization_conn, :gitlab_oauth_state)

    callback_conn =
      authorization_conn
      |> recycle()
      |> get(~p"/auth/gitlab/callback?code=valid-gitlab-code&state=#{state}")

    assert redirected_to(callback_conn) == "/accounts/settings"

    refute Tarakan.Repo.get_by(Tarakan.Accounts.Identity,
             account_id: account.id,
             provider: "gitlab"
           )
  end

  test "does not retain an encoded authority return path in the OAuth session" do
    query = URI.encode_query(%{"return_to" => "/%252f%252fattacker.example"})
    authorization_conn = get(build_conn(), "/auth/gitlab?#{query}")

    assert get_session(authorization_conn, :gitlab_oauth_return_to) == "/"
  end
end
