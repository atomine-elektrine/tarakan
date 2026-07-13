defmodule TarakanWeb.AccountLive.RegistrationTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tarakan.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/register")

      assert html =~ "Join Tarakan"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_account(account_fixture())
        |> live(~p"/accounts/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(account: %{"handle" => "valid-handle", "email" => "with spaces"})

      assert result =~ "Join Tarakan"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register account" do
    test "creates an active account and logs in immediately", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      email = unique_account_email()
      form = form(lv, "#registration_form", account: valid_account_attributes(email: email))

      render_submit(form)

      login_form = form(lv, "#registration_login_form")
      conn = follow_trigger_action(login_form, conn)

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/"
      assert %{confirmed_at: %DateTime{}} = Tarakan.Accounts.get_account_by_email(email)
    end

    test "does not reveal that an email is already registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      account = account_fixture(%{email: "test@email.com"})

      {:ok, _lv, html} =
        lv
        |> form("#registration_form",
          account: %{"handle" => unique_account_handle(), "email" => account.email}
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If an account matches those details, a sign-in link will arrive shortly."
      refute html =~ "has already been taken"
      refute html =~ account.email
    end

    test "does not reveal that a handle is already registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      account = account_fixture()
      email = unique_account_email()

      {:ok, _lv, html} =
        lv
        |> form("#registration_form",
          account: %{"handle" => account.handle, "email" => email}
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If an account matches those details, a sign-in link will arrive shortly."
      refute html =~ "has already been taken"
      refute Tarakan.Accounts.get_account_by_email(email)
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert login_html =~ "Log in"
    end
  end
end
