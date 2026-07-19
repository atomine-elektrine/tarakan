defmodule TarakanWeb.ProfileLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders a contributor profile with public contribution counts", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(2)})
    confirmation_fixture(scan, reviewer_account_fixture())

    {:ok, view, _html} = live(conn, ~p"/#{submitter.handle}")

    assert has_element?(view, "#profile-handle", submitter.handle)
    assert has_element?(view, "#profile-review-count", "1")
    assert has_element?(view, "#profile-finding-count", "2")
    assert has_element?(view, "#profile-repo-count", "1")
    assert has_element?(view, "#profile-reviews", "reviewed")
    assert has_element?(view, "#profile-repositories", repository.name)
    assert has_element?(view, "#profile-findings")
  end

  test "a moderator profile shows the role badge", %{conn: conn} do
    moderator = moderator_account_fixture()
    {:ok, view, _html} = live(conn, ~p"/#{moderator.handle}")
    assert has_element?(view, "#profile-role", "Moderator")
  end

  test "an unknown handle returns not found", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/#{"ghost-nobody"}") end
  end

  test "a submitter handle on the security page links to the profile", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

    {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")
    assert has_element?(view, ~s(a[href="/#{submitter.handle}"]))
  end

  test "finding rows link to the finding page", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    finding = hd(scan.findings || Tarakan.Repo.preload(scan, :findings).findings)

    {:ok, view, _html} = live(conn, ~p"/#{submitter.handle}")

    assert has_element?(
             view,
             ~s(#profile-finding-#{finding.public_id} a[href="/findings/#{finding.public_id}"])
           )
  end
end
