defmodule Tarakan.ReputationTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts.Scope
  alias Tarakan.Discussion
  alias Tarakan.Reputation

  defp public_finding(submitter \\ nil) do
    submitter = submitter || github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings
    {submitter, scan, finding}
  end

  describe "cast_vote" do
    test "records, changes, and toggles off a vote" do
      {_author, _scan, finding} = public_finding()
      voter = Scope.for_account(account_fixture())
      canonical = finding.canonical_finding

      assert {:ok, %{score: 1, my_vote: 1}} =
               Reputation.cast_vote(voter, "canonical_finding", canonical.id, 1)

      assert {:ok, %{score: -1, my_vote: -1}} =
               Reputation.cast_vote(voter, "canonical_finding", canonical.id, -1)

      # Re-casting the same value clears the vote.
      assert {:ok, %{score: 0, my_vote: 0}} =
               Reputation.cast_vote(voter, "canonical_finding", canonical.id, -1)
    end

    test "refuses a vote on your own finding" do
      {author, _scan, finding} = public_finding()

      assert {:error, :own_content} =
               Reputation.cast_vote(
                 Scope.for_account(author),
                 "canonical_finding",
                 finding.canonical_finding.id,
                 1
               )
    end

    test "refuses every reporter's self-vote after duplicate reports assimilate" do
      {first_author, scan, first} = public_finding()
      second_author = account_fixture()

      second_scan =
        scan_fixture(scan.repository, second_author, %{
          "findings_json" => findings_json_fixture(1)
        })

      [second] = second_scan.findings
      assert second.canonical_finding.id == first.canonical_finding.id

      for author <- [first_author, second_author] do
        assert {:error, :own_content} =
                 Reputation.cast_vote(
                   Scope.for_account(author),
                   "canonical_finding",
                   first.canonical_finding.id,
                   1
                 )
      end
    end

    test "refuses an anonymous voter" do
      {_author, _scan, finding} = public_finding()

      assert {:error, :unauthorized} =
               Reputation.cast_vote(nil, "canonical_finding", finding.canonical_finding.id, 1)
    end

    test "net score sums many voters" do
      {_author, _scan, finding} = public_finding()

      for _ <- 1..3,
          do:
            Reputation.cast_vote(
              Scope.for_account(account_fixture()),
              "canonical_finding",
              finding.canonical_finding.id,
              1
            )

      Reputation.cast_vote(
        Scope.for_account(account_fixture()),
        "canonical_finding",
        finding.canonical_finding.id,
        -1
      )

      assert %{score: 2} =
               Reputation.vote_summary("canonical_finding", finding.canonical_finding.id)
    end
  end

  describe "score" do
    test "a verified review dominates any plausible vote count" do
      {author, scan, finding} = public_finding()

      {:ok, comment} =
        Discussion.create_comment(Scope.for_account(author), %{finding | scan: scan}, %{
          "body" => "Evidence supplied by the reporter."
        })

      # Pile 10 new-account upvotes onto one authored comment.
      for _ <- 1..10,
          do: Reputation.cast_vote(Scope.for_account(account_fixture()), "comment", comment.id, 1)

      vote_only = Reputation.score(author)

      # Votes are capped per item, so 10 upvotes cannot exceed the cap.
      assert vote_only.votes <= 15
      assert vote_only.verification == 0

      # Now verify the review through the real quorum machinery.
      confirmation_fixture(scan, reviewer_account_fixture())
      confirmation_fixture(scan, reviewer_account_fixture())
      verified = Reputation.score(Tarakan.Accounts.get_account(author.id))

      assert verified.verification >= 30
      assert verified.verification > vote_only.votes
    end

    test "canonical votes rank the shared issue without crediting one reporter" do
      {author, _scan, finding} = public_finding()

      Reputation.cast_vote(
        Scope.for_account(reviewer_account_fixture()),
        "canonical_finding",
        finding.canonical_finding.id,
        1
      )

      assert Reputation.score(author).votes == 0
      assert Reputation.vote_summary("canonical_finding", finding.canonical_finding.id).score == 1
    end

    test "reputation never goes negative" do
      {author, scan, finding} = public_finding()

      {:ok, comment} =
        Discussion.create_comment(Scope.for_account(author), %{finding | scan: scan}, %{
          "body" => "Reporter context to test negative votes."
        })

      for _ <- 1..3,
          do:
            Reputation.cast_vote(Scope.for_account(account_fixture()), "comment", comment.id, -1)

      assert Reputation.score(author).total == 0
    end

    test "refresh caches the computed total on the account" do
      {author, scan, _finding} = public_finding()
      confirmation_fixture(scan, reviewer_account_fixture())
      confirmation_fixture(scan, reviewer_account_fixture())

      {:ok, refreshed} = Reputation.refresh(Tarakan.Accounts.get_account(author.id))
      assert refreshed.reputation >= 30
    end

    test "repeated reports earn verification credit once per canonical issue" do
      {author, first_scan, first} = public_finding()

      second_scan =
        scan_fixture(first_scan.repository, author, %{
          "findings_json" => findings_json_fixture(1)
        })

      [second] = second_scan.findings
      assert second.canonical_finding.id == first.canonical_finding.id

      confirmation_fixture(second_scan, reviewer_account_fixture())
      confirmation_fixture(second_scan, reviewer_account_fixture())

      assert Reputation.score(Tarakan.Accounts.get_account(author.id)).verification == 30
    end
  end

  describe "staking (abuse resistance)" do
    test "an unreviewed review's stake is at risk but never slashed by silence" do
      {author, _scan, _finding} = public_finding()

      s = Reputation.score(author)
      assert s.at_risk == Reputation.default_stake()
      assert s.slashed == 0
    end

    test "a single dispute does not slash — refutation needs a quorum" do
      {author, scan, _finding} = public_finding()
      confirmation_fixture(scan, reviewer_account_fixture(), "disputed")

      s = Reputation.score(Tarakan.Accounts.get_account(author.id))
      assert s.slashed == 0
    end

    test "a dispute quorum slashes the stake" do
      {author, scan, _finding} = public_finding()
      confirmation_fixture(scan, reviewer_account_fixture(), "disputed")
      confirmation_fixture(scan, reviewer_account_fixture(), "disputed")

      s = Reputation.score(Tarakan.Accounts.get_account(author.id))
      assert s.slashed == Reputation.default_stake()
      assert s.at_risk == 0
    end

    test "a verified review returns the stake and keeps the reward" do
      {author, scan, _finding} = public_finding()
      confirmation_fixture(scan, reviewer_account_fixture())
      confirmation_fixture(scan, reviewer_account_fixture())

      s = Reputation.score(Tarakan.Accounts.get_account(author.id))
      assert s.at_risk == 0
      assert s.slashed == 0
      assert s.verification >= 30
    end
  end
end
