defmodule Tarakan.LeaderboardTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Leaderboard

  # Verifies a submitter's review through the real quorum machinery so they
  # earn verification reputation.
  defp verified_contributor(findings) do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)

    scan =
      scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(findings)})

    confirmation_fixture(scan, reviewer_account_fixture())
    confirmation_fixture(scan, reviewer_account_fixture())
    submitter
  end

  test "ranks verified contributors by reputation and excludes zero-rep accounts" do
    _bigger = verified_contributor(3)
    _smaller = verified_contributor(1)

    unverified =
      github_account_fixture() |> then(fn a -> listed_github_repository_fixture(a) && a end)

    entries = Leaderboard.top(:reputation)

    # Every ranked account has positive reputation; the account that only
    # registered a repo (no verified work) is absent.
    assert Enum.all?(entries, &(&1.reputation.total > 0))
    refute Enum.any?(entries, &(&1.account.id == unverified.id))

    totals = Enum.map(entries, & &1.reputation.total)
    assert totals == Enum.sort(totals, :desc)
    # The contributor with more confirmed findings tops the board.
    assert hd(entries).stats.findings == 3
  end

  test "sorting by findings orders by finding count" do
    _many = verified_contributor(3)
    _few = verified_contributor(1)

    entries = Leaderboard.top(:findings)
    findings = Enum.map(entries, & &1.stats.findings)
    assert findings == Enum.sort(findings, :desc)
  end

  test "an empty record yields an empty leaderboard" do
    assert Leaderboard.top() == []
  end
end
