defmodule TarakanWeb.CommunityLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  test "the homepage shows the shoutbox and gates posting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#registry-shoutbox")
    refute has_element?(view, "#registry-presence")
    assert has_element?(view, "#shoutbox-empty")
    refute has_element?(view, "#shoutbox-form")
    assert has_element?(view, ~s(#registry-shoutbox a[href="/accounts/log-in"]))
  end

  test "a signed-in contributor posts a live escaped shout", %{conn: conn} do
    account = account_fixture()
    {:ok, view, _html} = live(log_in_account(conn, account), ~p"/")
    {:ok, observer, _html} = live(Phoenix.ConnTest.build_conn(), ~p"/")

    assert has_element?(view, "#shoutbox-form")
    assert has_element?(view, ~s(#shoutbox-form input[type="text"]))

    html =
      view
      |> form("#shoutbox-form", shout: %{body: "Reviewing <script>alert(1)</script> auth."})
      |> render_submit()

    assert has_element?(
             view,
             "#shoutbox-messages article",
             "Reviewing <script>alert(1)</script> auth."
           )

    assert has_element?(view, "#shoutbox-body-1[phx-mounted]")

    assert has_element?(
             observer,
             "#shoutbox-messages article",
             "Reviewing <script>alert(1)</script> auth."
           )

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert(1)</script>"
  end

  test "moderators can remove a shout from the homepage", %{conn: conn} do
    author = account_fixture()

    {:ok, shout} =
      Tarakan.Community.create_shout(Tarakan.Accounts.Scope.for_account(author), %{
        "body" => "Off-topic shout"
      })

    moderator = moderator_account_fixture()
    {:ok, view, _html} = live(log_in_account(conn, moderator), ~p"/")

    view
    |> element("#shout-#{shout.id} button", "Remove")
    |> render_click()

    assert has_element?(view, "#shout-#{shout.id}", "Removed by moderation")
    refute has_element?(view, "#shout-#{shout.id} button", "Remove")
  end

  test "the compact composer rejects blank messages without an inline error", %{conn: conn} do
    {:ok, view, _html} = live(log_in_account(conn, account_fixture()), ~p"/")

    assert has_element?(view, "#shoutbox-form input[required]")

    html =
      view
      |> form("#shoutbox-form", shout: %{body: "   "})
      |> render_submit()

    assert html =~ "Write a message before sending."
    refute has_element?(view, "#shoutbox-body-0-error")
    refute html =~ "be blank"
  end
end
