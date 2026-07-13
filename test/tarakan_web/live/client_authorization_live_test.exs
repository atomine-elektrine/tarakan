defmodule TarakanWeb.ClientAuthorizationLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_account

  test "approve/deny with no loaded authorization flashes instead of crashing", %{conn: conn} do
    # An unknown/expired user code leaves @authorization nil and hides the
    # buttons — but a queued or crafted event must not reach the context with
    # nil and raise a FunctionClauseError.
    {:ok, view, html} = live(conn, ~p"/client/authorize/UNKNOWNXY")
    assert html =~ "invalid or expired"

    assert render_click(view, "approve") =~ "expired or was already used"
    assert render_click(view, "deny") =~ "expired or was already used"
  end
end
