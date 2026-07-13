defmodule Tarakan.DiscussionTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts.Scope
  alias Tarakan.Discussion

  setup do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)

    scan =
      scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

    [finding] = scan.findings
    %{finding: %{finding | scan: scan}, repository: repository, submitter: submitter}
  end

  test "posts a top-level comment", %{finding: finding} do
    scope = Scope.for_account(account_fixture())

    assert {:ok, comment} =
             Discussion.create_comment(scope, finding, %{"body" => "Reproduced this locally."})

    assert comment.finding_id == finding.id
    assert comment.repository_id == finding.scan.repository_id
    assert comment.parent_id == nil
  end

  test "nests a reply under its parent", %{finding: finding} do
    scope = Scope.for_account(account_fixture())
    {:ok, parent} = Discussion.create_comment(scope, finding, %{"body" => "Is this admin-gated?"})

    {:ok, reply} =
      Discussion.create_comment(scope, finding, %{
        "body" => "No, the guard is bypassable via X.",
        "parent_id" => parent.id
      })

    assert reply.parent_id == parent.id

    [thread] = Discussion.list_comments(scope, finding)
    assert thread.id == parent.id
    assert [nested] = thread.replies
    assert nested.id == reply.id
    assert nested.depth == 1
  end

  test "rejects a reply whose parent belongs to another finding", %{
    finding: finding,
    submitter: submitter,
    repository: repository
  } do
    other_scan =
      scan_fixture(repository, submitter, %{
        "commit_sha" => random_commit_sha(),
        "findings_json" => findings_json_fixture(1)
      })

    [other_finding] = other_scan.findings
    scope = Scope.for_account(account_fixture())

    {:ok, foreign_parent} =
      Discussion.create_comment(scope, %{other_finding | scan: other_scan}, %{
        "body" => "On a different finding."
      })

    assert {:error, :invalid_parent} =
             Discussion.create_comment(scope, finding, %{
               "body" => "Should not attach.",
               "parent_id" => foreign_parent.id
             })
  end

  test "anonymous scope cannot post", %{finding: finding} do
    assert {:error, :unauthorized} =
             Discussion.create_comment(nil, finding, %{"body" => "hi"})
  end

  test "a moderator removes a comment, leaving a placeholder", %{finding: finding} do
    author = Scope.for_account(account_fixture())
    {:ok, comment} = Discussion.create_comment(author, finding, %{"body" => "Off-topic spam."})

    moderator = Scope.for_account(moderator_account_fixture())
    {:ok, get} = Discussion.get_comment(comment.id)

    assert {:ok, removed} =
             Discussion.remove_comment(moderator, get, %{"removed_reason" => "off_topic"})

    assert removed.removed_at

    # A non-moderator reader sees the placeholder, not the body.
    [placeholder] = Discussion.list_comments(author, finding)
    assert placeholder.removed_at
    assert placeholder.body == nil

    # The moderator still sees the original body for the audit trail.
    [full] = Discussion.list_comments(moderator, finding)
    assert full.body == "Off-topic spam."
  end
end
