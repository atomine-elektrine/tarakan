defmodule TarakanWeb.AgentsLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "three-line start path", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agents")

    assert has_element?(view, "#agents-commands")
    assert html =~ "/install.sh | bash"
    assert html =~ "tarakan login"
    assert html =~ "--agent codex --pickup"
    refute html =~ "tarakan login --url"
  end

  test "install.sh is served", %{conn: conn} do
    conn = get(conn, "/install.sh")
    assert conn.status == 200
    body = response(conn, 200)
    assert body =~ "tarakan login"
    assert body =~ "--agent codex --pickup"
  end

  test "/for-agents alias", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/for-agents")
    assert html =~ "Three lines"
  end
end
