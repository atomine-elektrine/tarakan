defmodule TarakanWeb.FindingVoteTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Tarakan.Accounts.Scope
  alias Tarakan.Discussion

  setup do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings
    %{finding: %{finding | scan: scan}, submitter: submitter}
  end

  test "a signed-in visitor upvotes a finding and the score updates", %{
    conn: conn,
    finding: finding
  } do
    conn = log_in_account(conn, account_fixture())
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")
    canonical_id = finding.canonical_finding.id

    view
    |> element(~s(#vote-canonical_finding-#{canonical_id} button[phx-value-vote="1"]))
    |> render_click()

    assert has_element?(view, "#vote-canonical_finding-#{canonical_id}", "1")
  end

  test "the submitter cannot vote on their own finding", %{
    conn: conn,
    finding: finding,
    submitter: submitter
  } do
    conn = log_in_account(conn, submitter)
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")
    canonical_id = finding.canonical_finding.id

    html =
      view
      |> element(~s(#vote-canonical_finding-#{canonical_id} button[phx-value-vote="1"]))
      |> render_click()

    assert html =~ "cannot vote on your own"
    assert has_element?(view, "#vote-canonical_finding-#{canonical_id}", "0")
  end

  test "anonymous vote clicks are gated to login", %{conn: conn, finding: finding} do
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")
    # Anonymous controls are disabled, so the buttons carry the disabled attr.
    assert has_element?(
             view,
             ~s(#vote-canonical_finding-#{finding.canonical_finding.id} button[disabled])
           )
  end

  test "a comment can be voted on", %{conn: conn, finding: finding} do
    {:ok, comment} =
      Discussion.create_comment(Scope.for_account(account_fixture()), finding, %{
        "body" => "This looks exploitable."
      })

    conn = log_in_account(conn, account_fixture())
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    view
    |> element(~s(#vote-comment-#{comment.id} button[phx-value-vote="1"]))
    |> render_click()

    assert has_element?(view, "#vote-comment-#{comment.id}", "1")
  end

  test "only the canonical finding on the security page carries a vote control", %{
    finding: finding
  } do
    conn = Phoenix.ConnTest.build_conn()
    {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")
    assert has_element?(view, "#vote-canonical_finding-#{finding.canonical_finding.id}")
    refute has_element?(view, "#vote-finding-#{finding.id}")
  end
end
