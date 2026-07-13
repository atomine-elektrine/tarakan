defmodule Tarakan.ActivityTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Activity
  alias Tarakan.Scans

  test "recent/1 includes only accepted disclosed scans and their verdicts" do
    submitter = github_account_fixture()
    repository = github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    scan = publish_scan(scan)

    entries = Activity.recent(10)

    assert Enum.count(entries, &(&1.kind == :verdict)) == 2

    assert %{findings_count: 1, provenance: "agent", owner: "openai"} =
             Enum.find(entries, &(&1.kind == :scan))

    assert %{owner: "openai", name: "codex"} =
             Enum.find(entries, &(&1.kind == :registration))

    assert Enum.any?(entries, &(&1.id == "scan-#{scan.id}"))
    assert Enum.any?(entries, &(&1.id == "reg-#{repository.id}"))
  end

  test "recent/1 respects the limit across kinds" do
    submitter = github_account_fixture()
    repository = github_repository_fixture(submitter)

    for _round <- 1..3 do
      repository |> scan_fixture(submitter) |> publish_scan()
    end

    assert length(Activity.recent(2)) == 2
  end

  test "registrations, scans, and verdicts hit the wire as they happen" do
    Activity.subscribe()

    submitter = github_account_fixture()
    repository = github_repository_fixture(submitter)
    repository_id = "reg-#{repository.id}"
    assert_received {:activity, %{kind: :registration, id: ^repository_id}}

    scan = scan_fixture(repository, submitter)
    scan_id = "scan-#{scan.id}"
    assert_received {:activity, %{kind: :scan, id: ^scan_id, findings_count: 0}}

    {:ok, _scan} =
      Scans.record_confirmation(scan, reviewer_account_fixture(), %{
        "verdict" => "confirmed",
        "notes" => "An independent reproduction of the already public review."
      })

    assert_received {:activity, %{kind: :verdict, verdict: "confirmed", scan_verified: false}}
  end

  defp publish_scan(scan) do
    scan = confirmation_fixture(scan, reviewer_account_fixture())
    scan = confirmation_fixture(scan, reviewer_account_fixture())

    scope = Tarakan.Accounts.Scope.for_account(moderator_account_fixture())

    {:ok, scan} =
      Scans.accept_scan(
        scope,
        scan,
        %{
          "moderation_reason" => "evidence_reviewed",
          "moderation_notes" =>
            "Two independent reviewers supplied reproducible evidence for the pinned commit."
        }
      )

    {:ok, scan} =
      Scans.update_visibility(scope, scan, "public_summary", %{
        "moderation_reason" => "safe_summary",
        "moderation_notes" =>
          "The public summary excludes reproduction details, paths, and private reviewer notes."
      })

    scan
  end
end
