defmodule TarakanWeb.RepositoryNewLiveTest do
  use TarakanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tarakan.HostedRepositories
  alias Tarakan.Repositories

  setup :register_and_log_in_account

  setup do
    on_exit(fn ->
      File.rm_rf(Application.fetch_env!(:tarakan, Tarakan.HostedRepositories)[:root])
    end)

    :ok
  end

  test "requires authentication" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/repositories/new")
    assert path =~ "/accounts/log-in"
  end

  test "creates a hosted repository and navigates to it", %{conn: conn, account: account} do
    {:ok, view, _html} = live(conn, ~p"/repositories/new")

    assert has_element?(view, "#new-repository-form")

    view
    |> form("#new-repository-form", repository: %{name: "from-the-ui"})
    |> render_submit()

    assert_redirect(view, "/#{account.handle}/from-the-ui")
    assert HostedRepositories.resolve(account.handle, "from-the-ui")

    # the bare GitHub-style path must dispatch through the hosted scope
    {:ok, repo_view, _html} = live(conn, "/#{account.handle}/from-the-ui")
    assert has_element?(repo_view, "#repository-name")
  end

  test "shows validation errors inline", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/repositories/new")

    html =
      view
      |> form("#new-repository-form", repository: %{name: "bad name"})
      |> render_submit()

    assert html =~ "may only contain"
  end

  describe "remote registration" do
    setup %{conn: conn} do
      %{conn: log_in_account(conn, github_account_fixture())}
    end

    test "registers a repository and opens its public record", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/repositories/new")

      view
      |> form("#register-remote-form", repository: %{url: "github.com/OpenAI/Codex"})
      |> render_submit()

      assert_redirect(view, ~p"/github.com/openai/codex")
      assert Repositories.get_github_repository("openai", "codex")

      {:ok, record_view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(record_view, "#repository-name")
      assert has_element?(record_view, "#repository-source-link")
      assert has_element?(record_view, "#github-metadata")
      assert has_element?(record_view, "#repository-submitter")
      assert has_element?(record_view, "#scans-empty")
    end

    test "shows a useful error for an invalid repository", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/repositories/new")

      view
      |> form("#register-remote-form",
        repository: %{url: "https://example.com/not/github"}
      )
      |> render_submit()

      assert has_element?(view, "#repository_url-error")
    end

    test "rejects a valid-looking repository that GitHub cannot find", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/repositories/new")

      view
      |> form("#register-remote-form", repository: %{url: "missing/repository"})
      |> render_submit()

      assert has_element?(view, "#repository_url-error")
      refute Repositories.get_github_repository("missing", "repository")
    end

    test "shows the same safe error for a private repository", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/repositories/new")

      view
      |> form("#register-remote-form", repository: %{url: "private/repository"})
      |> render_submit()

      assert has_element?(view, "#repository_url-error")
      refute Repositories.get_github_repository("private", "repository")
    end
  end
end
