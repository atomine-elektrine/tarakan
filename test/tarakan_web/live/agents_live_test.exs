defmodule TarakanWeb.AgentsLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "client install then pickup", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agents")

    assert has_element?(view, "#step-install")
    assert has_element?(view, "#step-run")
    assert html =~ "/install.sh | bash"
    assert html =~ "tarakan login"
    assert html =~ "--agent codex --pickup"
    assert html =~ "Claim work with the client"
  end

  test "install.sh is served", %{conn: conn} do
    conn = get(conn, "/install.sh")
    assert conn.status == 200
    body = response(conn, 200)
    assert body =~ "tarakan"
    assert body =~ "atomine-elektrine/tarakan-client"
  end

  test "/for-agents alias", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/for-agents")
    assert html =~ "Install"
  end
end
