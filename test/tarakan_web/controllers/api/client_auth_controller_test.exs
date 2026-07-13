defmodule TarakanWeb.API.ClientAuthControllerTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tarakan.Accounts.ApiCredentials

  test "browser approval exchanges a device code for one scoped credential", %{conn: conn} do
    start_response =
      conn
      |> post(~p"/api/client-auth/start", %{client_name: "Tarakan CLI on laptop"})
      |> json_response(201)

    assert start_response["device_code"] =~ "trkd_"
    assert start_response["user_code"] =~ ~r/^[A-Z2-7]{4}-[A-Z2-7]{4}$/

    assert start_response["verification_uri_complete"] =~
             "/client/authorize/#{start_response["user_code"]}"

    pending =
      build_conn()
      |> post(~p"/api/client-auth/exchange", %{device_code: start_response["device_code"]})
      |> json_response(400)

    assert pending == %{"error" => "authorization_pending"}

    account = account_fixture()

    {:ok, view, _html} =
      build_conn()
      |> log_in_account(account)
      |> live(~p"/client/authorize/#{start_response["user_code"]}")

    assert has_element?(view, "#client-authorization-code")
    assert has_element?(view, "#client-authorization-approve-button")

    view
    |> element("#client-authorization-approve-button")
    |> render_click()

    assert has_element?(view, "#client-authorization-approved")

    exchange_response =
      build_conn()
      |> post(~p"/api/client-auth/exchange", %{device_code: start_response["device_code"]})
      |> json_response(200)

    assert exchange_response["token"] =~ "trkn_"
    assert exchange_response["token_type"] == "Bearer"
    assert "tasks:read" in exchange_response["scopes"]
    assert "reviews:verify" in exchange_response["scopes"]

    assert {:ok, ^account, credential} = ApiCredentials.authenticate(exchange_response["token"])
    assert credential.name == "Tarakan CLI on laptop"

    consumed =
      build_conn()
      |> post(~p"/api/client-auth/exchange", %{device_code: start_response["device_code"]})
      |> json_response(400)

    assert consumed == %{"error" => "invalid_device_code"}

    revoke_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{exchange_response["token"]}")
      |> delete(~p"/api/client-auth/session")

    assert response(revoke_conn, 204) == ""
    assert :error = ApiCredentials.authenticate(exchange_response["token"])
  end

  test "the browser can deny a login without issuing a credential", %{conn: conn} do
    start_response =
      conn
      |> post(~p"/api/client-auth/start", %{})
      |> json_response(201)

    {:ok, view, _html} =
      build_conn()
      |> log_in_account(account_fixture())
      |> live(~p"/client/authorize/#{start_response["user_code"]}")

    view
    |> element("#client-authorization-deny-button")
    |> render_click()

    assert has_element?(view, "#client-authorization-denied")

    denied =
      build_conn()
      |> post(~p"/api/client-auth/exchange", %{device_code: start_response["device_code"]})
      |> json_response(403)

    assert denied == %{"error" => "access_denied"}
  end

  test "authorization page requires a signed-in web account", %{conn: conn} do
    start_response =
      conn
      |> post(~p"/api/client-auth/start", %{})
      |> json_response(201)

    assert {:error, {:redirect, %{to: path}}} =
             live(build_conn(), ~p"/client/authorize/#{start_response["user_code"]}")

    assert path == ~p"/accounts/log-in"
  end

  test "a stale web session reauthenticates and returns to the approval", %{conn: conn} do
    start_response =
      conn
      |> post(~p"/api/client-auth/start", %{})
      |> json_response(201)

    return_to = ~p"/client/authorize/#{start_response["user_code"]}"
    stale_at = DateTime.add(DateTime.utc_now(:second), -9 * 60, :minute)

    assert {:error, {:redirect, %{to: path}}} =
             build_conn()
             |> log_in_account(account_fixture(), token_authenticated_at: stale_at)
             |> live(return_to)

    assert path == TarakanWeb.AccountAuth.reauth_path(return_to)
  end

  test "invalid device codes fail without revealing authorization state", %{conn: conn} do
    response =
      conn
      |> post(~p"/api/client-auth/exchange", %{device_code: "not-a-device-code"})
      |> json_response(400)

    assert response == %{"error" => "invalid_device_code"}
  end
end
