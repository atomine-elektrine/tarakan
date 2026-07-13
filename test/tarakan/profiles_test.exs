defmodule Tarakan.ProfilesTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Profiles

  test "get_profile is case-insensitive and preloads identities" do
    account = account_fixture(%{handle: "signalghost"})

    profile = Profiles.get_profile("SignalGhost")
    assert profile.id == account.id
    assert Ecto.assoc_loaded?(profile.identities)
  end

  test "get_profile returns nil for an unknown handle" do
    assert Profiles.get_profile("nobody-here") == nil
  end

  test "contribution stats count only public work" do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(2)})

    verifier = reviewer_account_fixture()
    confirmation_fixture(scan, verifier)

    submitter_stats = Profiles.contribution_stats(submitter)
    assert submitter_stats.reviews == 1
    assert submitter_stats.findings == 2
    assert submitter_stats.repositories == 1
    assert submitter_stats.verdicts == 0

    verifier_stats = Profiles.contribution_stats(verifier)
    # One legacy report check is projected onto both canonical findings.
    assert verifier_stats.verdicts == 2
    assert verifier_stats.reviews == 0
  end

  test "a restricted review does not count toward a profile" do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

    {:ok, _restricted} =
      Tarakan.Scans.update_visibility(
        Tarakan.Accounts.Scope.for_account(moderator_account_fixture()),
        scan,
        "restricted",
        %{
          "moderation_reason" => "takedown_review",
          "moderation_notes" => "Restricted in this test to confirm profiles stay public-only."
        }
      )

    stats = Profiles.contribution_stats(submitter)
    assert stats.reviews == 0
    assert stats.findings == 0
  end

  test "repeated report occurrences count as one canonical finding" do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)

    for _ <- 1..2 do
      scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    end

    stats = Profiles.contribution_stats(submitter)
    assert stats.reviews == 2
    assert stats.findings == 1
  end

  test "recent activity lists reviews and verdicts newest first" do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    confirmation_fixture(scan, submitter |> then(fn _ -> reviewer_account_fixture() end))

    [review | _] = Profiles.recent_activity(submitter)
    assert review.kind == :review
    assert review.repository.id == repository.id
  end
end
