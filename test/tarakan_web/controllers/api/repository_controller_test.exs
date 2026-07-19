defmodule TarakanWeb.API.RepositoryControllerTest do
  use TarakanWeb.ConnCase, async: true

  alias Tarakan.Accounts.ApiCredentials
  alias Tarakan.Repositories

  setup %{conn: conn} do
    account = github_account_fixture()
    token = api_token(account)
    %{conn: conn, account: account, token: token}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp api_token(account) do
    {:ok, token, _credential} =
      ApiCredentials.create(account, %{
        name: "registry importer",
        scopes: ["findings:submit"]
      })

    token
  end

  test "rejects registration without a token", %{conn: conn} do
    conn = post(conn, ~p"/api/repositories", %{"url" => "openai/codex"})
    assert json_response(conn, 401)["error"] =~ "API token"
  end

  test "registers a public repository by owner/name", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> post(~p"/api/repositories", %{"url" => "openai/codex"})

    assert %{"repository" => repo} = json_response(conn, 200)
    assert repo["owner"] == "openai"
    assert repo["name"] == "codex"
    assert repo["host"] == "github.com"
    assert repo["record_url"] =~ "/github.com/openai/codex"
  end

  test "is idempotent on re-register", %{conn: conn, token: token, account: account} do
    {:ok, first} = Repositories.register_github_repository("openai/codex", account)

    conn = conn |> authed(token) |> post(~p"/api/repositories", %{"url" => "openai/codex"})
    assert %{"repository" => repo} = json_response(conn, 200)
    assert repo["owner"] == first.owner
    assert repo["name"] == first.name
  end

  test "requires a url", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> post(~p"/api/repositories", %{})
    assert json_response(conn, 422)["errors"]["url"] == ["is required"]
  end

  test "lists reviewable repositories", %{conn: conn, token: token, account: account} do
    {:ok, _repo} = Repositories.register_github_repository("openai/codex", account)

    conn = conn |> authed(token) |> get(~p"/api/repositories?status=unscanned")
    assert %{"repositories" => repos} = json_response(conn, 200)
    assert Enum.any?(repos, &(&1["owner"] == "openai" and &1["name"] == "codex"))
  end
end
