defmodule TarakanWeb.AccountLive.ConfirmationTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tarakan.AccountsFixtures

  alias Tarakan.Accounts

  setup do
    %{unconfirmed_account: unconfirmed_account_fixture(), confirmed_account: account_fixture()}
  end

  describe "Magic-link login" do
    test "renders login page for a legacy unconfirmed account", %{
      conn: conn,
      unconfirmed_account: account
    } do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_login_instructions(account, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in/#{token}")
      refute html =~ "Confirm"
      assert html =~ "Log in"
    end

    test "renders login page for confirmed account", %{conn: conn, confirmed_account: account} do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_login_instructions(account, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in/#{token}")
      assert html =~ "Stay logged in on this device"
    end

    test "renders login page for already logged in account", %{
      conn: conn,
      confirmed_account: account
    } do
      conn = log_in_account(conn, account)

      token =
        extract_account_token(fn url ->
          Accounts.deliver_login_instructions(account, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in/#{token}")
      assert html =~ "Log in"
    end

    test "logs in a legacy unconfirmed account with the given token once", %{
      conn: conn,
      unconfirmed_account: account
    } do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_login_instructions(account, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/#{token}")

      form = form(lv, "#login_form", %{"account" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"

      assert Accounts.get_account!(account.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/accounts/log-in/#{token}")
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed account in without changing confirmed_at", %{
      conn: conn,
      confirmed_account: account
    } do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_login_instructions(account, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/#{token}")

      form = form(lv, "#login_form", %{"account" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_account!(account.id).confirmed_at == account.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/accounts/log-in/#{token}")
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/accounts/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end
end
