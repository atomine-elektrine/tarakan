defmodule TarakanWeb.CoreComponentsTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TarakanWeb.CoreComponents

  test "ordinary flash toasts auto-dismiss with kind-specific delays" do
    info =
      render_component(&CoreComponents.flash/1, %{
        kind: :info,
        flash: %{"info" => "Saved"}
      })

    error =
      render_component(&CoreComponents.flash/1, %{
        kind: :error,
        flash: %{"error" => "Failed"}
      })

    assert info =~ ~s(phx-hook="AutoDismiss")
    assert info =~ ~s(data-auto-dismiss-ms="5000")
    assert error =~ ~s(data-auto-dismiss-ms="8000")
  end

  test "connection status alerts can opt out of auto-dismiss" do
    html =
      render_component(&CoreComponents.flash/1, %{
        id: "connection-error",
        kind: :error,
        flash: %{"error" => "Disconnected"},
        auto_dismiss: false
      })

    refute html =~ ~s(phx-hook="AutoDismiss")
    refute html =~ "data-auto-dismiss-ms"
  end
end
