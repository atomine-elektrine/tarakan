defmodule TarakanWeb.AccountLive.SettingsTest do
  use TarakanWeb.ConnCase, async: true

  alias Tarakan.Accounts
  import Phoenix.LiveViewTest
  import Tarakan.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, view, html} =
        conn
        |> log_in_account(account_fixture())
        |> live(~p"/accounts/settings")

      assert html =~ "Save email"
      assert html =~ "Save password"
      assert html =~ "Connected code hosts"
      assert html =~ "GitHub"
      assert html =~ "GitLab"
      assert has_element?(view, "#api-reference", "API reference")
      assert has_element?(view, "#api-reference-base-url", "/api")
      assert html =~ "/client-auth/exchange"
      assert html =~ "/repositories"
      assert html =~ "/requests/:id/claim/renew"
      assert html =~ "/:host/:owner/:name/reports"
    end

    test "marks an attached code-host identity as connected", %{conn: conn} do
      {:ok, view, _html} =
        conn
        |> log_in_account(github_account_fixture())
        |> live(~p"/accounts/settings")

      assert has_element?(view, "#settings-github-identity", "Connected")
      assert has_element?(view, "#settings-gitlab-identity", "Connect")
    end

    test "redirects if account is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/accounts/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "generates and independently revokes a client credential", %{conn: conn} do
      account = account_fixture()

      {:ok, view, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/accounts/settings")

      assert html =~ "Client credentials"
      refute has_element?(view, "#api-token-value")

      view
      |> form("#api-credential-form", %{
        "credential" => %{
          "name" => "Task reader",
          "scopes" => ["tasks:read"]
        }
      })
      |> render_submit()

      token =
        view
        |> element("#api-token-value")
        |> render()
        |> String.replace(~r/<[^>]+>/, "")
        |> String.trim()

      assert {:ok, fetched} = Accounts.fetch_account_by_api_token(token)
      assert fetched.id == account.id

      [credential] = Tarakan.Accounts.ApiCredentials.list(account)
      assert credential.name == "Task reader"
      assert credential.scopes == ["tasks:read"]
      assert has_element?(view, "#api-credential-#{credential.id}")

      view
      |> element("#revoke-api-credential-#{credential.id}")
      |> render_click()

      assert :error = Accounts.fetch_account_by_api_token(token)
      refute has_element?(view, "#revoke-api-credential-#{credential.id}")
    end

    test "can bind a least-privilege credential to one repository", %{conn: conn} do
      account = github_account_fixture()
      repository = github_repository_fixture(account)

      {:ok, view, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/accounts/settings")

      view
      |> form("#api-credential-form", %{
        "credential" => %{
          "name" => "Codex reader",
          "repository" => "openai/codex",
          "scopes" => ["tasks:read"]
        }
      })
      |> render_submit()

      token =
        view
        |> element("#api-token-value")
        |> render()
        |> String.replace(~r/<[^>]+>/, "")
        |> String.trim()

      assert {:ok, ^account, credential} =
               Tarakan.Accounts.ApiCredentials.authenticate(token)

      assert credential.repository_id == repository.id
      assert credential.scopes == ["tasks:read"]
    end

    test "redirects if account is not in sudo mode", %{conn: conn} do
      stale_at = DateTime.add(DateTime.utc_now(:second), -9 * 60, :minute)

      {:ok, conn} =
        conn
        |> log_in_account(account_fixture(), token_authenticated_at: stale_at)
        |> live(~p"/accounts/settings")
        |> follow_redirect(conn, ~p"/accounts/log-in?return_to=%2Faccounts%2Fsettings")

      assert conn.resp_body =~ "sign-in older than 2 hours for sensitive settings"
    end
  end

  describe "SSH keys" do
    @describetag :tmp_dir

    defp generate_public_key(tmp_dir) do
      path = Path.join(tmp_dir, "key-#{System.unique_integer([:positive])}")
      {_output, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-f", path, "-N", "", "-q"])
      File.read!(path <> ".pub")
    end

    test "adds and removes a key", %{conn: conn, tmp_dir: tmp_dir} do
      account = account_fixture()

      {:ok, view, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/accounts/settings")

      assert html =~ "SSH keys"

      view
      |> form("#ssh-key-form",
        ssh_key: %{name: "laptop", public_key: generate_public_key(tmp_dir)}
      )
      |> render_submit()

      assert has_element?(view, "#ssh-key-list", "laptop")
      assert has_element?(view, "#ssh-key-list", "SHA256:")

      [key] = Tarakan.Accounts.SshKeys.list_for_account(account)

      view
      |> element("#delete-ssh-key-#{key.id}")
      |> render_click()

      refute has_element?(view, "#ssh-key-list")
      assert Tarakan.Accounts.SshKeys.list_for_account(account) == []
    end

    test "rejects an invalid key inline", %{conn: conn} do
      {:ok, view, _html} =
        conn
        |> log_in_account(account_fixture())
        |> live(~p"/accounts/settings")

      html =
        view
        |> form("#ssh-key-form", ssh_key: %{name: "junk", public_key: "not a key"})
        |> render_submit()

      assert html =~ "is not a supported OpenSSH public key"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      account = account_fixture()
      %{conn: log_in_account(conn, account), account: account}
    end

    test "updates the account email", %{conn: conn, account: account} do
      new_email = unique_account_email()

      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> form("#email_form", %{
          "account" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_account_by_email(account.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "account" => %{"email" => "with spaces"}
        })

      assert result =~ "Save email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> form("#email_form", %{
          "account" => %{"email" => account.email}
        })
        |> render_submit()

      assert result =~ "Save email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      account = account_fixture()
      %{conn: log_in_account(conn, account), account: account}
    end

    test "updates the account password", %{conn: conn, account: account} do
      new_password = valid_account_password()

      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      form =
        form(lv, "#password_form", %{
          "account" => %{
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/accounts/settings"

      assert get_session(new_password_conn, :account_token) != get_session(conn, :account_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_account_by_email_and_password(account.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "account" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save password"
      assert result =~ "should be at least 15 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> form("#password_form", %{
          "account" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save password"
      assert result =~ "should be at least 15 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      account = account_fixture()
      email = unique_account_email()

      token =
        extract_account_token(fn url ->
          Accounts.deliver_account_update_email_instructions(
            %{account | email: email},
            account.email,
            url
          )
        end)

      %{conn: log_in_account(conn, account), token: token, email: email, account: account}
    end

    test "updates the account email once", %{
      conn: conn,
      account: account,
      token: token,
      email: email
    } do
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_account_by_email(account.email)
      assert Accounts.get_account_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, account: account} do
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_account_by_email(account.email)
    end

    test "redirects if account is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
