defmodule TarakanWeb.ExploreLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Tarakan.Activity

  test "renders the wire: registrations and unverified public reviews", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

    {:ok, view, _html} = live(conn, ~p"/explore")

    assert has_element?(view, "#activity-wire")
    assert has_element?(view, "#wire-reg-#{repository.id}", "openai/codex")
    assert has_element?(view, "#wire-scan-#{scan.id}", "@#{submitter.handle}")
    assert has_element?(view, "#wire-scan-#{scan.id}", "1 finding")
  end

  test "filters the wire by kind", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter)

    {:ok, view, _html} = live(conn, ~p"/explore")

    view |> element("#explore-filter button", "Registrations") |> render_click()

    assert has_element?(view, "#wire-reg-#{repository.id}")
    refute has_element?(view, "#wire-scan-#{scan.id}")

    view |> element("#explore-filter button", "Reports") |> render_click()

    assert has_element?(view, "#wire-scan-#{scan.id}")
    refute has_element?(view, "#wire-reg-#{repository.id}")
  end

  test "new activity lands on the wire without a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    assert has_element?(view, "#activity-wire-empty")

    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    Activity.broadcast_registration(repository)

    assert has_element?(view, "#wire-reg-#{repository.id}", "openai/codex")
  end

  test "verdicts on the wire show who ruled and how", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    reviewer = reviewer_account_fixture()
    confirmation_fixture(scan, reviewer)

    {:ok, view, _html} = live(conn, ~p"/explore")

    assert render(view) =~ "@#{reviewer.handle}"
    assert render(view) =~ "confirmed a finding on"
  end

  test "handles link to contributor profiles", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter)

    {:ok, view, _html} = live(conn, ~p"/explore")

    assert view
           |> element("#wire-scan-#{scan.id} a[href='/#{submitter.handle}']")
           |> render() =~ "@#{submitter.handle}"
  end

  test "comments join the wire live and on reload", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    {:ok, view, _html} = live(conn, ~p"/explore")

    commenter = account_fixture()
    scope = Tarakan.Accounts.Scope.for_account(commenter)

    {:ok, comment} =
      Tarakan.Discussion.create_comment(scope, %{finding | scan: scan}, %{
        "body" => "Reproduced on a clean checkout."
      })

    assert has_element?(view, "#wire-comment-#{comment.id}", "@#{commenter.handle}")
    assert has_element?(view, "#wire-comment-#{comment.id}", "commented on")

    {:ok, reloaded, _html} = live(conn, ~p"/explore")
    assert has_element?(reloaded, "#wire-comment-#{comment.id}")

    reloaded |> element("#explore-filter button", "Comments") |> render_click()
    assert has_element?(reloaded, "#wire-comment-#{comment.id}")
    refute has_element?(reloaded, "#wire-scan-#{scan.id}")
  end

  test "search narrows the wire by handle or repository", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter)

    {:ok, view, _html} = live(conn, ~p"/explore")

    view
    |> form("#explore-search-form", %{"q" => submitter.handle})
    |> render_change()

    assert has_element?(view, "#wire-scan-#{scan.id}")
    refute has_element?(view, "#wire-reg-#{repository.id}")

    view
    |> form("#explore-search-form", %{"q" => "no-such-thing"})
    |> render_change()

    assert has_element?(view, "#activity-wire-empty")
  end

  test "shows watcher presence", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    assert has_element?(view, "#explore-watchers")
    assert view |> element("#explore-watchers") |> render() =~ "watching"
  end

  test "hot findings rail ranks upvoted findings and refreshes on votes", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings
    canonical = finding.canonical_finding

    # Hot rail excludes pure single-run unconfirmed noise; second detection qualifies.
    _second =
      scan_fixture(repository, account_fixture(), %{
        "findings_json" => findings_json_fixture(1),
        "commit_sha" => scan.commit_sha
      })

    canonical = Tarakan.Repo.get!(Tarakan.Scans.CanonicalFinding, canonical.id)

    {:ok, view, _html} = live(conn, ~p"/explore")

    assert has_element?(view, "#hot-findings", "No findings upvoted this week.")

    voter = Tarakan.Accounts.Scope.for_account(account_fixture())
    {:ok, _summary} = Tarakan.Reputation.cast_vote(voter, "canonical_finding", canonical.id, 1)

    assert has_element?(view, "#hot-finding-#{canonical.id}", "+1")

    assert view
           |> element("#hot-finding-#{canonical.id}")
           |> render() =~ ~s(href="/findings/)
  end
end
