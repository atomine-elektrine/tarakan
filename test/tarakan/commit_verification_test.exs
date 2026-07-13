defmodule Tarakan.CommitVerificationTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Scans
  alias Tarakan.Work

  @mismatched_sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    creator = github_account_fixture()
    %{creator: creator, repository: github_repository_fixture(creator)}
  end

  test "scan submission rejects commit metadata for a different SHA", %{
    creator: creator,
    repository: repository
  } do
    attrs = valid_scan_attributes(%{"commit_sha" => @mismatched_sha})

    assert {:error, :commit_mismatch} = Scans.submit_scan(repository, creator, attrs)
  end

  test "review-task proposal rejects commit metadata for a different SHA", %{
    creator: creator,
    repository: repository
  } do
    attrs = valid_review_task_attributes(%{"commit_sha" => @mismatched_sha})

    assert {:error, :commit_mismatch} = Work.create_task(repository, creator, attrs)
  end
end
