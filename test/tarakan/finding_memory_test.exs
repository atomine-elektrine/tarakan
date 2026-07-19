defmodule Tarakan.FindingMemoryTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.FindingMemory
  alias Tarakan.Scans.CanonicalFinding

  describe "fingerprint/1" do
    test "collapses path variants" do
      base = %{file_path: "lib/auth.ex", line_start: 10, line_end: 12, title: "SQL injection"}
      dotted = %{base | file_path: "./lib/auth.ex"}
      slashy = %{base | file_path: "lib//auth.ex"}
      cased = %{base | file_path: "Lib/Auth.ex"}

      assert FindingMemory.fingerprint(base) == FindingMemory.fingerprint(dotted)
      assert FindingMemory.fingerprint(base) == FindingMemory.fingerprint(slashy)
      assert FindingMemory.fingerprint(base) == FindingMemory.fingerprint(cased)
    end

    test "collapses confidence title prefixes and ignores line_end drift" do
      base = %{
        file_path: "lib/auth.ex",
        line_start: 10,
        line_end: 10,
        title: "SQL injection in login"
      }

      prefixed = %{base | title: "Verified: Likely: SQL injection in login"}
      ranged = %{base | line_end: 40}
      punct = %{base | title: "SQL injection in login."}

      assert FindingMemory.fingerprint(base) == FindingMemory.fingerprint(prefixed)
      assert FindingMemory.fingerprint(base) == FindingMemory.fingerprint(ranged)
      assert FindingMemory.fingerprint(base) == FindingMemory.fingerprint(punct)
    end

    test "still separates different lines or titles" do
      a = %{file_path: "lib/a.ex", line_start: 1, line_end: 1, title: "Issue A"}
      b = %{a | line_start: 2}
      c = %{a | title: "Issue B"}

      refute FindingMemory.fingerprint(a) == FindingMemory.fingerprint(b)
      refute FindingMemory.fingerprint(a) == FindingMemory.fingerprint(c)
    end
  end

  describe "assimilate near-duplicates" do
    setup do
      submitter = github_account_fixture()
      repository = listed_github_repository_fixture(submitter)
      %{repository: repository, submitter: submitter}
    end

    test "merges agent path and title variants into one canonical", %{
      repository: repository,
      submitter: submitter
    } do
      commit_sha = random_commit_sha()

      first =
        scan_fixture(repository, submitter, %{
          "commit_sha" => commit_sha,
          "findings_json" =>
            finding_doc("lib/example/module_1.ex", 10, 15, "Unsanitized input reaches query")
        })

      second =
        scan_fixture(repository, account_fixture(), %{
          "commit_sha" => commit_sha,
          "findings_json" =>
            finding_doc(
              "./lib/example/module_1.ex",
              10,
              99,
              "Verified: Unsanitized input reaches query."
            )
        })

      [f1] = first.findings
      [f2] = second.findings

      assert f1.file_path == "lib/example/module_1.ex"
      assert f2.file_path == "lib/example/module_1.ex"
      assert f1.canonical_finding_id == f2.canonical_finding_id
      assert f2.disposition == "matches_existing"

      canonical = Repo.get!(CanonicalFinding, f1.canonical_finding_id)
      assert canonical.detections_count == 2
    end

    test "upgrades a legacy fingerprint when a v2 match arrives", %{
      repository: repository,
      submitter: submitter
    } do
      commit_sha = random_commit_sha()

      first =
        scan_fixture(repository, submitter, %{
          "commit_sha" => commit_sha,
          "findings_json" => finding_doc("lib/legacy.ex", 5, 20, "Buffer overflow")
        })

      [occurrence] = first.findings
      legacy_fp = FindingMemory.legacy_fingerprint(occurrence)
      modern_fp = FindingMemory.fingerprint(occurrence)

      # Simulate a pre-v2 row still keyed by the old hash.
      if legacy_fp != modern_fp do
        canonical = Repo.get!(CanonicalFinding, occurrence.canonical_finding_id)

        canonical
        |> Ecto.Changeset.change(fingerprint: legacy_fp)
        |> Repo.update!()

        second =
          scan_fixture(repository, account_fixture(), %{
            "commit_sha" => commit_sha,
            "findings_json" => finding_doc("lib/legacy.ex", 5, 20, "Buffer overflow")
          })

        [f2] = second.findings
        assert f2.canonical_finding_id == occurrence.canonical_finding_id

        upgraded = Repo.get!(CanonicalFinding, occurrence.canonical_finding_id)
        assert upgraded.fingerprint == modern_fp
        assert upgraded.detections_count == 2
      else
        # When v1 and v2 coincide (same lines collapsing), assimilation still works.
        second =
          scan_fixture(repository, account_fixture(), %{
            "commit_sha" => commit_sha,
            "findings_json" => finding_doc("lib/legacy.ex", 5, 20, "Buffer overflow")
          })

        [f2] = second.findings
        assert f2.canonical_finding_id == occurrence.canonical_finding_id
      end
    end
  end

  defp finding_doc(file, line_start, line_end, title) do
    Jason.encode!(%{
      "tarakan_scan_format" => 1,
      "findings" => [
        %{
          "file" => file,
          "line_start" => line_start,
          "line_end" => line_end,
          "severity" => "high",
          "title" => title,
          "description" => "Evidence body for assimilation tests."
        }
      ]
    })
  end
end
