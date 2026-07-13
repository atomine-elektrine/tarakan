defmodule TarakanWeb.RepositoryCodeLiveTest do
  use TarakanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tarakan.Accounts.Scope
  alias Tarakan.RepositoryCode.Cache
  alias Tarakan.Scans

  @default_commit_sha String.duplicate("7", 40)
  @historical_commit_sha String.duplicate("8", 40)

  setup do
    Cache.clear()
    repository = listed_github_repository_fixture()
    %{repository: repository}
  end

  test "repository roots open the code browser by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex")
    render_async(view, 1_000)

    assert has_element?(view, "#repository-navigation")
    assert has_element?(view, "#repository-code-tab[aria-current='page']", "Code")

    assert has_element?(
             view,
             "#repository-overview-tab[href='/github.com/openai/codex/security']"
           )

    assert has_element?(view, "#code-tree")
  end

  test "the legacy code entry route still opens the default tree", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/code")
    render_async(view, 1_000)

    assert has_element?(view, "#code-tree")
    assert has_element?(view, "#code-commit-sha", String.slice(@default_commit_sha, 0, 7))
  end

  test "browses directories at the freshly resolved default commit", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, ~p"/github.com/openai/codex/code/#{@default_commit_sha}")

    render_async(view, 1_000)

    assert has_element?(view, "#code-tree")
    assert has_element?(view, "#code-tree-entries [id^='code-entry-']", "lib")

    assert has_element?(
             view,
             "#code-tree-entries a[href='/github.com/openai/codex/code/#{@default_commit_sha}/README.md']"
           )
  end

  test "round-trips encoded spaces, percent signs, fragments, and Unicode filenames", %{
    conn: conn
  } do
    root = "/github.com/openai/codex/code/#{@default_commit_sha}"
    {:ok, tree_view, _html} = live(conn, root)
    render_async(tree_view, 1_000)

    assert has_element?(
             tree_view,
             "a[href='#{root}/space%20%23%20100%25.txt']",
             "space # 100%.txt"
           )

    assert has_element?(tree_view, "a[href='#{root}/%CE%BB.ex']", "λ.ex")

    {:ok, encoded_view, _html} = live(conn, root <> "/space%20%23%20100%25.txt")
    render_async(encoded_view, 1_000)
    assert has_element?(encoded_view, "#code-file", "space # 100%.txt")
    assert has_element?(encoded_view, "#L1 code", "# Codex")

    {:ok, unicode_view, _html} = live(conn, root <> "/%CE%BB.ex")
    render_async(unicode_view, 1_000)
    assert has_element?(unicode_view, "#code-file", "λ.ex")
    assert has_element?(unicode_view, "#L1 code", "defmodule Codex")
  end

  test "folder and file rows show findings for the pinned commit", %{
    conn: conn,
    repository: repository
  } do
    scan = finding_scan_fixture(repository, account_fixture(), @default_commit_sha)
    _scan = publish_full_scan(repository, scan)

    {:ok, root_view, _html} = live(conn, ~p"/github.com/openai/codex")
    render_async(root_view, 1_000)

    assert has_element?(root_view, "#code-entry-bGli-findings", "1 finding")
    assert has_element?(root_view, "#code-reference", "1 finding")

    {:ok, lib_view, _html} =
      live(conn, ~p"/github.com/openai/codex/code/#{@default_commit_sha}/lib")

    render_async(lib_view, 1_000)

    assert has_element?(lib_view, "#code-entry-bGliL2NvZGV4LmV4-findings", "1 finding")
  end

  test "public summaries do not leak file paths through code-row badges", %{
    conn: conn,
    repository: repository
  } do
    scan = finding_scan_fixture(repository, account_fixture(), @default_commit_sha)
    scan = confirmation_fixture(scan, reviewer_account_fixture())
    scan = confirmation_fixture(scan, reviewer_account_fixture())
    moderator_scope = Scope.for_account(moderator_account_fixture())

    {:ok, accepted} = Scans.accept_scan(moderator_scope, scan, moderation_attributes())

    {:ok, _summary} =
      Scans.update_visibility(
        moderator_scope,
        accepted,
        "public_summary",
        moderation_attributes()
      )

    {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex")
    render_async(view, 1_000)
    html = render(view)

    refute has_element?(view, "[id$='-findings']")
    refute html =~ "lib/codex.ex"
  end

  test "renders escaped plain-text lines with stable anchors and selection", %{conn: conn} do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/github.com/openai/codex/code/#{@default_commit_sha}/README.md?lines=1"
      )

    render_async(view, 1_000)

    assert has_element?(view, "#code-file")
    assert has_element?(view, "#L1.bg-panel")
    assert has_element?(view, "#L1 code", "# Codex")

    assert has_element?(
             view,
             "#L1 a[href='/github.com/openai/codex/code/#{@default_commit_sha}/README.md?lines=1#L1']"
           )
  end

  test "rejects an out-of-range single-line selection", %{conn: conn} do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/github.com/openai/codex/code/#{@default_commit_sha}/README.md?lines=1000001"
      )

    render_async(view, 1_000)

    assert has_element?(view, "#invalid-line-selection")
    refute has_element?(view, "#code-lines .bg-panel")
  end

  test "renders hostile source as escaped text rather than executable markup", %{conn: conn} do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/github.com/openai/codex/code/#{@default_commit_sha}/unsafe.html"
      )

    render_async(view, 1_000)
    html = render(view)

    assert has_element?(view, "#L1 code", "</code><script id=\"source-xss\">alert(1)</script>")
    refute has_element?(view, "script#source-xss")
    assert html =~ "&lt;/code&gt;&lt;script id=&quot;source-xss&quot;&gt;"
  end

  test "rejects guessed historical SHAs on the generic browser", %{conn: conn} do
    paths = [
      ~p"/github.com/openai/codex/code/#{@historical_commit_sha}",
      ~p"/github.com/openai/codex/code/#{@historical_commit_sha}/README.md"
    ]

    for path <- paths do
      {:ok, view, _html} = live(conn, path)
      render_async(view, 1_000)

      assert has_element?(view, "#code-browser-error")
      assert has_element?(view, "#code-browser-error", "Source not found")
      refute has_element?(view, "#code-tree")
      refute has_element?(view, "#code-file")
    end
  end

  test "rejects encoded traversal and backslash paths at the route boundary", %{conn: conn} do
    unsafe_paths = [
      "/github.com/openai/codex/code/#{@default_commit_sha}/lib/%2E%2E/README.md",
      "/github.com/openai/codex/code/#{@default_commit_sha}/lib/%5C..%5Csecret"
    ]

    for path <- unsafe_paths do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#code-browser-error", "Invalid path")
      refute has_element?(view, "#code-file")
    end
  end

  test "an authorized opaque finding route opens historical source without leaking path in links",
       %{
         conn: conn,
         repository: repository
       } do
    submitter = account_fixture()
    scan = finding_scan_fixture(repository, submitter, @historical_commit_sha)
    finding = hd(scan.findings)

    {:ok, view, _html} =
      live(log_in_account(conn, submitter), ~p"/findings/#{finding.public_id}/code")

    render_async(view, 1_000)

    assert has_element?(view, "#finding-code-context")
    assert has_element?(view, "#code-file")
    assert has_element?(view, "#L2.bg-panel")
    refute has_element?(view, "#source-breadcrumbs a")
    assert has_element?(view, "#L2 a[href='/findings/#{finding.public_id}/code#L2']")
  end

  test "the opaque route does not reveal a moderator-restricted finding to anonymous visitors",
       %{
         conn: conn,
         repository: repository
       } do
    scan = finding_scan_fixture(repository, account_fixture(), @historical_commit_sha)
    finding = hd(scan.findings)

    moderator_scope = Scope.for_account(moderator_account_fixture())

    {:ok, _restricted} =
      Scans.update_visibility(moderator_scope, scan, "restricted", moderation_attributes())

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/findings/#{finding.public_id}/code")
    end
  end

  test "marks a reported line range that does not exist at the pinned commit", %{
    conn: conn,
    repository: repository
  } do
    submitter = account_fixture()
    scan = finding_scan_fixture(repository, submitter, @historical_commit_sha, 99)
    finding = hd(scan.findings)

    {:ok, view, _html} =
      live(log_in_account(conn, submitter), ~p"/findings/#{finding.public_id}/code")

    render_async(view, 1_000)

    assert has_element?(view, "#finding-line-outside-file")
    refute has_element?(view, "#code-lines .bg-panel")
  end

  test "finding source routes reject enumerable integer identifiers", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, "/findings/1/code")
    end
  end

  test "a connected finding view is evicted when a moderator restricts the scan", %{
    conn: conn,
    repository: repository
  } do
    scan = finding_scan_fixture(repository, account_fixture(), @historical_commit_sha)
    scan = publish_full_scan(repository, scan)
    finding = hd(scan.findings)

    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}/code")
    render_async(view, 1_000)
    assert has_element?(view, "#code-file")

    moderator_scope = Scope.for_account(moderator_account_fixture())

    assert {:ok, _restricted} =
             Scans.update_visibility(moderator_scope, scan, "restricted", moderation_attributes())

    assert_redirect(view, ~p"/github.com/openai/codex")
  end

  test "the default code page is uncached but remains indexable", %{conn: conn} do
    conn = get(conn, ~p"/github.com/openai/codex")

    assert html_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == []
  end

  test "commit-pinned code routes prohibit caches and search indexing", %{conn: conn} do
    conn = get(conn, ~p"/github.com/openai/codex/code/#{@default_commit_sha}")

    assert html_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "opaque finding routes prohibit caches and search indexing", %{
    conn: conn,
    repository: repository
  } do
    scan = finding_scan_fixture(repository, account_fixture(), @historical_commit_sha)
    finding = repository |> publish_full_scan(scan) |> Map.fetch!(:findings) |> hd()

    conn = get(conn, ~p"/findings/#{finding.public_id}/code")

    assert html_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  defp finding_scan_fixture(repository, submitter, commit_sha, line_start \\ 2) do
    document =
      Jason.encode!(%{
        "tarakan_scan_format" => 1,
        "findings" => [
          %{
            "file" => "lib/codex.ex",
            "line_start" => line_start,
            "line_end" => line_start,
            "severity" => "high",
            "title" => "Authorization is not checked",
            "description" => "A request reaches a privileged operation without a policy check."
          }
        ]
      })

    scan_fixture(repository, submitter, %{
      "commit_sha" => commit_sha,
      "findings_json" => document
    })
  end

  defp publish_full_scan(repository, scan) do
    repository
    |> Tarakan.Repositories.Repository.participation_changeset(%{
      participation_mode: "maintainer_verified"
    })
    |> Tarakan.Repo.update!()

    scan = confirmation_fixture(scan, reviewer_account_fixture())
    scan = confirmation_fixture(scan, reviewer_account_fixture())
    moderator_scope = Scope.for_account(moderator_account_fixture())

    {:ok, accepted} = Scans.accept_scan(moderator_scope, scan, moderation_attributes())

    {:ok, disclosed} =
      Scans.update_visibility(
        moderator_scope,
        accepted,
        "public",
        moderation_attributes(%{"sensitive_data_reviewed" => "true"})
      )

    disclosed
  end

  defp moderation_attributes(overrides \\ %{}) do
    Enum.into(overrides, %{
      "moderation_reason" => "evidence_reviewed",
      "moderation_notes" =>
        "Independent evidence and disclosure boundaries were reviewed for this exact commit."
    })
  end
end
