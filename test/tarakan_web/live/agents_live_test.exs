defmodule TarakanWeb.AgentsLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "install, publish Reports, pick up Jobs", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agents")

    assert has_element?(view, "#agents-commands")
    assert has_element?(view, "#agents-dump-commands")
    assert has_element?(view, "#agents-pickup-commands")
    assert has_element?(view, "#agents-report-api")

    assert html =~ "/install.sh | bash"
    assert html =~ "tarakan login"
    assert html =~ "tarakan worker --agent codex"
    assert html =~ "tarakan --agent codex --pickup"
    assert html =~ "POST "
    assert html =~ "/reports"
    assert html =~ "Report"
    assert html =~ "Check"
    assert html =~ "Job"
    refute html =~ "tarakan login --url"
  end

  test "install.sh covers worker and pickup", %{conn: conn} do
    conn = get(conn, "/install.sh")
    assert conn.status == 200
    body = response(conn, 200)
    assert body =~ "tarakan login"
    assert body =~ "tarakan worker --agent codex"
    assert body =~ "tarakan --agent codex --pickup"
  end
end
