defmodule TarakanWeb.FindingDiscussionTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Tarakan.Accounts.Scope
  alias Tarakan.Discussion

  setup do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings
    %{finding: %{finding | scan: scan}, repository: repository}
  end

  test "anonymous visitors see the discussion but are prompted to sign in", %{
    conn: conn,
    finding: finding
  } do
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    assert has_element?(view, "#finding-discussion")
    assert has_element?(view, "#finding-comment-login")
    assert has_element?(view, "#finding-no-comments")
    refute has_element?(view, "#finding-comment-form")
  end

  test "a signed-in account posts a comment", %{conn: conn, finding: finding} do
    conn = log_in_account(conn, account_fixture())
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    view
    |> form("#finding-comment-form", %{"body" => "Reproduced against the pinned commit."})
    |> render_submit()

    assert has_element?(view, "#finding-comment-count", "1 comment")
    assert render(view) =~ "Reproduced against the pinned commit."
    refute has_element?(view, "#finding-no-comments")
  end

  test "a reply nests under its parent", %{conn: conn, finding: finding} do
    author = account_fixture()

    {:ok, parent} =
      Discussion.create_comment(Scope.for_account(author), finding, %{"body" => "Parent comment."})

    conn = log_in_account(conn, account_fixture())
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    view |> element("#comment-#{parent.id} button", "Reply") |> render_click()

    view
    |> form("#reply-form-#{parent.id}", %{"body" => "A threaded reply."})
    |> render_submit()

    assert has_element?(view, "#comment-#{parent.id} #comment-#{last_comment_id()}")
    assert has_element?(view, "#finding-comment-count", "2 comments")
  end

  test "a moderator can remove a comment and it shows as a placeholder", %{
    conn: conn,
    finding: finding
  } do
    author = account_fixture()

    {:ok, comment} =
      Discussion.create_comment(Scope.for_account(author), finding, %{"body" => "Spammy comment."})

    conn = log_in_account(conn, moderator_account_fixture())
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    assert has_element?(view, "#comment-#{comment.id} button", "Remove")

    view
    |> element("#comment-#{comment.id} button", "Remove")
    |> render_click()

    assert has_element?(view, "#comment-#{comment.id}", "Removed by moderation")
  end

  test "restricted findings expose no discussion to anonymous visitors", %{
    conn: conn,
    repository: repository
  } do
    submitter = github_account_fixture(%{handle: "restricted-author"})
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    {:ok, _restricted} =
      Tarakan.Scans.update_visibility(
        Scope.for_account(moderator_account_fixture()),
        scan,
        "restricted",
        %{
          "moderation_reason" => "takedown_review",
          "moderation_notes" =>
            "Restricted in this test to confirm discussion follows finding disclosure."
        }
      )

    assert_error_sent 404, fn -> get(conn, ~p"/findings/#{finding.public_id}") end
  end

  defp last_comment_id do
    import Ecto.Query

    Tarakan.Repo.one(
      from c in Tarakan.Discussion.Comment, order_by: [desc: c.id], limit: 1, select: c.id
    )
  end
end
