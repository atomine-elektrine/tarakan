defmodule TarakanWeb.AccountLive.LoginTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tarakan.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ "Log in"
      assert html =~ "Continue with GitHub"
      assert html =~ "Continue with GitLab"
      assert html =~ "Email me a login link"
    end

    test "preserves a protected route stored in the session", %{conn: conn} do
      return_to = "/client/authorize/ABCD-EFGH"

      {:ok, view, _html} =
        conn
        |> init_test_session(%{account_return_to: return_to})
        |> live(~p"/accounts/log-in")

      assert has_element?(
               view,
               "#login_form_password input[name='account[return_to]'][value='#{return_to}']"
             )

      assert has_element?(
               view,
               "#github-login-button[href='/auth/github?return_to=%2Fclient%2Fauthorize%2FABCD-EFGH']"
             )
    end
  end

  describe "account login - magic link" do
    test "sends magic link email when account exists", %{conn: conn} do
      account = account_fixture()

      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", account: %{email: account.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If your email is in our system"

      assert Tarakan.Repo.get_by!(Tarakan.Accounts.AccountToken, account_id: account.id).context ==
               "login"
    end

    test "does not disclose if account is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", account: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "account login - password" do
    test "redirects if account logs in with valid credentials", %{conn: conn} do
      account = account_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      form =
        form(lv, "#login_form_password",
          account: %{
            identifier: account.handle,
            password: valid_account_password(),
            remember_me: true
          }
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      form =
        form(lv, "#login_form_password",
          account: %{identifier: "test@email.com", password: "123456"}
        )

      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Invalid handle, email, or password"

      assert redirected_to(conn) == ~p"/accounts/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to native registration when Create one is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Create one")
        |> render_click()
        |> follow_redirect(conn, ~p"/accounts/register")

      assert login_html =~ "Join Tarakan"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      account = account_fixture()
      %{account: account, conn: log_in_account(conn, account)}
    end

    test "shows login page with email filled in", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ "Reauthenticate or connect another code host"
      assert html =~ "Email me a login link"

      assert html =~
               ~s(<input type="email" name="account[email]" id="login_form_magic_email" value="#{account.email}")
    end
  end
end
