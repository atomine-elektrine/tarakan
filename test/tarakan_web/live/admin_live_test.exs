defmodule TarakanWeb.AdminLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tarakan.Accounts
  alias Tarakan.Accounts.Account
  alias Tarakan.Repo

  setup %{conn: conn} do
    admin =
      account_fixture()
      |> Account.authorization_changeset(%{
        state: "active",
        platform_role: "admin",
        trust_tier: "reviewer"
      })
      |> Repo.update!()

    %{admin: admin, conn: log_in_account(conn, admin)}
  end

  test "admin sees account summary, search, and management links", %{conn: conn} do
    target = account_fixture(%{handle: "managed-account"})

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#admin-dashboard")
    assert has_element?(view, "#admin-summary-admins")
    assert has_element?(view, "#admin-account-filter")
    assert has_element?(view, "#admin-account-#{target.id}-manage")

    view
    |> form("#admin-account-filter", filters: %{query: "managed-account"})
    |> render_change()

    assert has_element?(view, "#admin-account-#{target.id}-manage")
  end

  test "admin updates account standing, role, and trust tier", %{conn: conn} do
    target = account_fixture()

    {:ok, view, _html} = live(conn, ~p"/admin/accounts/#{target.id}")

    assert has_element?(view, "#admin-account")
    assert has_element?(view, "#admin-authorization-form")

    view
    |> form("#admin-authorization-form",
      authorization: %{
        state: "active",
        platform_role: "moderator",
        trust_tier: "reviewer"
      }
    )
    |> render_submit()

    updated = Accounts.get_account!(target.id)
    assert updated.state == "active"
    assert updated.platform_role == "moderator"
    assert updated.trust_tier == "reviewer"
    assert has_element?(view, "#admin-authorization-form")
  end

  test "ordinary members cannot open platform administration", %{conn: _admin_conn} do
    member =
      account_fixture() |> Account.authorization_changeset(%{state: "active"}) |> Repo.update!()

    conn = log_in_account(build_conn(), member)

    assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/admin")
    assert path == ~p"/"
    assert flash["error"] == "Administrator access is required."
  end

  test "last administrator cannot remove their own authority", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/admin/accounts/#{admin.id}")

    view
    |> form("#admin-authorization-form",
      authorization: %{
        state: "active",
        platform_role: "member",
        trust_tier: "reviewer"
      }
    )
    |> render_submit()

    assert Accounts.get_account!(admin.id).platform_role == "admin"
    assert has_element?(view, "#admin-authorization-form")
  end
end
