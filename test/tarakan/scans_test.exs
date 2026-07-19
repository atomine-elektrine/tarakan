defmodule Tarakan.ScansTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts.Scope
  alias Tarakan.Audit.Event
  alias Tarakan.Repositories
  alias Tarakan.Scans
  alias Tarakan.FindingMemory
  alias Tarakan.Scans.{CanonicalFinding, Finding, Scan, ScanFormat}

  describe "ScanFormat.parse/1" do
    test "parses a valid document into finding attributes" do
      assert {:ok, [finding]} = ScanFormat.parse(findings_json_fixture(1))

      assert finding.file_path == "lib/example/module_1.ex"
      assert finding.severity == "high"
      assert finding.line_start == 10
      assert finding.line_end == 15
      assert finding.position == 0
    end

    test "treats nil, blank input, and an empty findings list as a clean scan" do
      assert ScanFormat.parse(nil) == {:ok, []}
      assert ScanFormat.parse("   ") == {:ok, []}
      assert ScanFormat.parse(~s({"tarakan_scan_format": 1, "findings": []})) == {:ok, []}
    end

    test "defaults line_end to line_start" do
      json =
        Jason.encode!(%{
          "tarakan_scan_format" => 1,
          "findings" => [
            %{
              "file" => "mix.exs",
              "line_start" => 3,
              "severity" => "info",
              "title" => "Example",
              "description" => "Example"
            }
          ]
        })

      assert {:ok, [%{line_start: 3, line_end: 3}]} = ScanFormat.parse(json)
    end

    test "caps finding line numbers before they reach the code viewer" do
      json =
        Jason.encode!(%{
          "tarakan_scan_format" => 1,
          "findings" => [
            %{
              "file" => "lib/auth.ex",
              "line_start" => 1_000_001,
              "severity" => "high",
              "title" => "Out-of-range line",
              "description" => "Line hints must be bounded before rendering."
            }
          ]
        })

      assert {:error,
              "findings[0]: line_start must be a positive integer no greater than 1000000"} =
               ScanFormat.parse(json)
    end

    test "requires an ordered line range with a starting line" do
      base = %{
        "file" => "lib/auth.ex",
        "severity" => "high",
        "title" => "Invalid line range",
        "description" => "Source links need an unambiguous range."
      }

      only_end =
        Jason.encode!(%{
          "tarakan_scan_format" => 1,
          "findings" => [Map.put(base, "line_end", 20)]
        })

      reversed =
        Jason.encode!(%{
          "tarakan_scan_format" => 1,
          "findings" => [Map.merge(base, %{"line_start" => 20, "line_end" => 10})]
        })

      assert {:error, "findings[0]: line_end requires line_start"} = ScanFormat.parse(only_end)

      assert {:error, "findings[0]: line_end must not be before line_start"} =
               ScanFormat.parse(reversed)
    end

    test "ignores unknown keys for forward compatibility" do
      json =
        Jason.encode!(%{
          "tarakan_scan_format" => 1,
          "harness" => "someday",
          "findings" => [
            %{
              "file" => "mix.exs",
              "severity" => "low",
              "title" => "Example",
              "description" => "Example",
              "confidence" => 0.8
            }
          ]
        })

      assert {:ok, [%{file_path: "mix.exs"}]} = ScanFormat.parse(json)
    end

    test "rejects malformed documents with precise errors" do
      assert {:error, "is not valid JSON"} = ScanFormat.parse("{nope")
      assert {:error, "must be a JSON object"} = ScanFormat.parse("[]")

      assert {:error, "tarakan_scan_format must be 1"} =
               ScanFormat.parse(~s({"tarakan_scan_format": 2, "findings": []}))

      assert {:error, ~s(must include "tarakan_scan_format" or "tarakan_review_format": 1)} =
               ScanFormat.parse(~s({"findings": []}))

      assert {:ok, [%{file_path: "lib/a.ex", severity: "low"}]} =
               ScanFormat.parse(
                 ~s({"tarakan_review_format": 1, "findings": [{"file": "lib/a.ex", "line_start": 1, "severity": "low", "title": "t", "description": "d"}]})
               )

      assert {:error, "findings must be a list"} =
               ScanFormat.parse(~s({"tarakan_scan_format": 1, "findings": {}}))

      assert {:error, "must include a findings list"} =
               ScanFormat.parse(~s({"tarakan_scan_format": 1}))
    end

    test "rejects invalid findings with the offending index" do
      json =
        Jason.encode!(%{
          "tarakan_scan_format" => 1,
          "findings" => [
            %{"file" => "a.ex", "severity" => "high", "title" => "ok", "description" => "ok"},
            %{"file" => "b.ex", "severity" => "urgent", "title" => "bad", "description" => "bad"}
          ]
        })

      assert {:error, "findings[1]: severity must be one of critical, high, medium, low, info"} =
               ScanFormat.parse(json)
    end

    test "caps the number of findings per scan" do
      json = findings_json_fixture(ScanFormat.max_findings() + 1)
      assert {:error, "must contain at most 200 findings"} = ScanFormat.parse(json)
    end

    test "rejects absolute, traversal, and oversized finding paths" do
      paths = [
        "/etc/passwd",
        "../secret",
        Enum.map_join(1..65, "/", fn _index -> "a" end)
      ]

      for path <- paths do
        json =
          Jason.encode!(%{
            "tarakan_scan_format" => 1,
            "findings" => [
              %{
                "file" => path,
                "severity" => "high",
                "title" => "Unsafe path",
                "description" => "The path must remain pinned inside the repository tree."
              }
            ]
          })

        assert {:error, "findings[0]: file must be a safe repository-relative path"} =
                 ScanFormat.parse(json)
      end
    end

    test "canonicalizes common agent path variants on ingest" do
      for {input, expected} <- [
            {"./lib/auth.ex", "lib/auth.ex"},
            {"lib//auth.ex", "lib/auth.ex"},
            {"lib\\auth.ex", "lib/auth.ex"},
            {"lib/./auth.ex", "lib/auth.ex"}
          ] do
        json =
          Jason.encode!(%{
            "tarakan_scan_format" => 1,
            "findings" => [
              %{
                "file" => input,
                "severity" => "high",
                "title" => "Path cleanup",
                "description" => "Agent path noise should collapse."
              }
            ]
          })

        assert {:ok, [%{file_path: ^expected}]} = ScanFormat.parse(json)
      end
    end
  end

  describe "submit_scan/3" do
    setup do
      submitter = github_account_fixture()
      %{submitter: submitter, repository: github_repository_fixture(submitter)}
    end

    test "records findings publicly and updates the record at submission", %{
      repository: repository,
      submitter: submitter
    } do
      attrs = valid_scan_attributes(%{"findings_json" => findings_json_fixture(2)})

      assert {:ok, scan} = Scans.submit_scan(repository, submitter, attrs)

      assert scan.findings_count == 2
      assert scan.commit_committed_at == ~U[2026-07-01 12:00:00.000000Z]
      assert [%Finding{position: 0}, %Finding{position: 1}] = scan.findings
      assert scan.submitted_by.id == submitter.id
      refute Scans.Scan.verified?(scan)
      assert scan.review_status == "quarantined"
      assert scan.visibility == "public"

      repository = Repositories.get_github_repository("openai", "codex")
      assert repository.scan_count == 1
      assert repository.open_findings_count == 2
      assert repository.verified_findings_count == 0
      assert repository.status == "findings"
      assert repository.last_scanned_at

      assert [%{id: id, details_visible: true}] = Scans.list_scans(repository)
      assert id == scan.id
    end

    test "records a human-authored privacy review without agent metadata", %{
      repository: repository,
      submitter: submitter
    } do
      attrs = %{
        "commit_sha" => random_commit_sha(),
        "provenance" => "human",
        "review_kind" => "privacy_review",
        "notes" => "Mapped account deletion through the export and analytics paths.",
        "findings_json" => findings_json_fixture(1)
      }

      assert {:ok, scan} = Scans.submit_scan(repository, submitter, attrs)

      assert scan.provenance == "human"
      assert scan.review_kind == "privacy_review"
      assert scan.model == nil
      assert scan.prompt_version == nil
      assert scan.findings_count == 1
    end

    test "requires model and prompt metadata when an agent participated", %{
      repository: repository,
      submitter: submitter
    } do
      attrs = %{
        "commit_sha" => random_commit_sha(),
        "provenance" => "hybrid",
        "review_kind" => "threat_model",
        "findings_json" => nil
      }

      assert {:error, changeset} = Scans.submit_scan(repository, submitter, attrs)
      assert "can't be blank" in errors_on(changeset).model
      assert "can't be blank" in errors_on(changeset).prompt_version
    end

    test "rejects unknown provenance and review kinds", %{
      repository: repository,
      submitter: submitter
    } do
      attrs =
        valid_scan_attributes(%{
          "provenance" => "probably_human",
          "review_kind" => "vibes"
        })

      assert {:error, changeset} = Scans.submit_scan(repository, submitter, attrs)
      assert "is invalid" in errors_on(changeset).provenance
      assert "is invalid" in errors_on(changeset).review_kind
    end

    test "preserves a clean scan as a first-class result", %{
      repository: repository,
      submitter: submitter
    } do
      assert {:ok, scan} = Scans.submit_scan(repository, submitter, valid_scan_attributes())

      assert scan.findings == []
      assert scan.findings_count == 0

      repository = Repositories.get_github_repository("openai", "codex")
      assert repository.scan_count == 1
      assert repository.open_findings_count == 0
      assert repository.status == "reviewed"
    end

    test "a later empty scan cannot clear an earlier finding report", %{
      repository: repository,
      submitter: submitter
    } do
      scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(3)})

      other_account = account_fixture()
      scan_fixture(repository, other_account, %{"findings_json" => nil})

      repository = Repositories.get_github_repository("openai", "codex")
      assert repository.scan_count == 2
      assert repository.open_findings_count == 3
      assert repository.status == "findings"
    end

    test "normalizes and validates the commit SHA", %{
      repository: repository,
      submitter: submitter
    } do
      sha = String.upcase(random_commit_sha())
      attrs = valid_scan_attributes(%{"commit_sha" => "  #{sha}  "})

      assert {:ok, scan} = Scans.submit_scan(repository, submitter, attrs)
      assert scan.commit_sha == String.downcase(sha)

      attrs = valid_scan_attributes(%{"commit_sha" => "abc123"})
      assert {:error, changeset} = Scans.submit_scan(repository, submitter, attrs)
      assert "must be a full 40-character commit SHA" in errors_on(changeset).commit_sha
    end

    test "submission reloads canonical repository metadata", %{
      repository: repository,
      submitter: submitter
    } do
      forged_repository = %{repository | owner: "missing", name: "forged"}

      assert {:ok, scan} =
               Scans.submit_scan(forged_repository, submitter, valid_scan_attributes())

      assert scan.repository.owner == "openai"
      assert scan.repository.name == "codex"
    end

    test "rejects a commit GitHub does not know", %{
      repository: repository,
      submitter: submitter
    } do
      attrs = valid_scan_attributes(%{"commit_sha" => "dead" <> String.duplicate("0", 36)})

      assert {:error, :commit_not_found} = Scans.submit_scan(repository, submitter, attrs)
      assert Repositories.get_github_repository("openai", "codex").scan_count == 0
    end

    test "rejects invalid findings documents", %{repository: repository, submitter: submitter} do
      attrs = valid_scan_attributes(%{"findings_json" => "{nope"})

      assert {:error, changeset} = Scans.submit_scan(repository, submitter, attrs)
      assert "is not valid JSON" in errors_on(changeset).findings_json
    end

    test "suspended accounts cannot submit reviews", %{
      repository: repository,
      submitter: submitter
    } do
      suspended =
        submitter
        |> Tarakan.Accounts.Account.authorization_changeset(%{state: "suspended"})
        |> Repo.update!()

      assert {:error, :unauthorized} =
               Scans.submit_scan(repository, suspended, valid_scan_attributes())
    end

    test "authorization is rechecked from locked account state before insert", %{
      repository: repository,
      submitter: submitter
    } do
      stale_scope = Scope.for_account(submitter)

      submitter
      |> Tarakan.Accounts.Account.authorization_changeset(%{state: "suspended"})
      |> Repo.update!()

      assert {:error, :unauthorized} =
               Scans.submit_scan(stale_scope, repository, valid_scan_attributes())

      assert Scans.list_scans(stale_scope, repository) == []
    end

    test "probation accounts can submit at most three reviews per day", %{
      repository: repository,
      submitter: submitter
    } do
      for _number <- 1..3 do
        assert {:ok, _scan} =
                 Scans.submit_scan(repository, submitter, valid_scan_attributes())
      end

      assert {:error, :submission_limit} =
               Scans.submit_scan(repository, submitter, valid_scan_attributes())
    end

    test "uses run ids for retry idempotency without blocking independent runs", %{
      repository: repository,
      submitter: submitter
    } do
      attrs = valid_scan_attributes(%{"run_id" => "run-stable-1"})

      assert {:ok, _scan} = Scans.submit_scan(repository, submitter, attrs)
      assert {:error, changeset} = Scans.submit_scan(repository, submitter, attrs)
      assert "this agent run was already submitted" in errors_on(changeset).run_id

      assert {:ok, _scan} =
               Scans.submit_scan(repository, submitter, Map.put(attrs, "run_id", "run-stable-2"))
    end

    test "assimilates exact findings from independent reports", %{
      repository: repository,
      submitter: submitter
    } do
      commit_sha = random_commit_sha()
      document = findings_json_fixture(1)

      first =
        scan_fixture(repository, submitter, %{
          "commit_sha" => commit_sha,
          "findings_json" => document
        })

      second =
        scan_fixture(repository, account_fixture(), %{
          "commit_sha" => commit_sha,
          "findings_json" => document
        })

      [first_finding] = first.findings
      [second_finding] = second.findings
      assert first_finding.canonical_finding_id == second_finding.canonical_finding_id
      assert first_finding.disposition == "new"
      assert second_finding.disposition == "matches_existing"

      canonical = Repo.get!(CanonicalFinding, first_finding.canonical_finding_id)
      assert canonical.detections_count == 2
      assert canonical.distinct_submitters_count == 2

      repository = Repositories.get_github_repository(repository.owner, repository.name)
      assert repository.scan_count == 2
      assert repository.open_findings_count == 1

      assert [%{public_id: public_id, detections_count: 2}] =
               FindingMemory.list_repository_memory(repository)

      assert public_id == canonical.public_id
    end

    test "broadcasts the review and the public record change at submission", %{
      repository: repository,
      submitter: submitter
    } do
      Scans.subscribe(repository.id)
      Repositories.subscribe()

      {:ok, scan} = Scans.submit_scan(repository, submitter, valid_scan_attributes())

      scan_id = scan.id
      repository_id = repository.id
      assert_received {:scan_submitted, %{id: ^scan_id}}
      assert_received {:repository_record_updated, %{id: ^repository_id}}
    end
  end

  describe "record_confirmation/3" do
    setup do
      submitter = github_account_fixture()
      repository = github_repository_fixture(submitter)

      scan =
        scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(2)})

      %{repository: repository, submitter: submitter, scan: scan}
    end

    test "verification requires two qualified human attestations", %{
      repository: repository,
      scan: scan
    } do
      confirmer = reviewer_account_fixture()

      assert {:ok, scan} =
               Scans.record_confirmation(scan, confirmer, %{
                 "verdict" => "confirmed",
                 "notes" => "Independently reproduced both findings against the pinned commit."
               })

      assert scan.confirmations_count == 1
      assert scan.disputes_count == 0
      refute Scans.Scan.verified?(scan)
      assert [confirmation] = scan.confirmations
      assert confirmation.account.id == confirmer.id
      assert confirmation.provenance == "human"

      assert {:ok, scan} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "confirmed",
                 "notes" =>
                   "Reproduced the same data flow and confirmed the impact independently."
               })

      assert scan.confirmations_count == 2
      assert Scans.Scan.verified?(scan)
      assert scan.review_status == "quarantined"
      assert [%{id: listed_id}] = Scans.list_scans(repository)
      assert listed_id == scan.id

      repository = Repositories.get_github_repository(repository.owner, repository.name)
      assert repository.verified_findings_count == 2
      assert repository.status == "findings"
    end

    test "stores a proof-of-concept as evidence and rejects an oversized one", %{scan: scan} do
      assert {:ok, updated} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "confirmed",
                 "notes" => "Reproduced the reported issue with a minimal failing test.",
                 "evidence" => "test('repro', t => t.throws(() => vulnerable(payload)))"
               })

      assert [confirmation] = updated.confirmations
      assert confirmation.evidence =~ "t.throws"

      assert {:error, changeset} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "confirmed",
                 "notes" => "Evidence exceeds the allowed length and must be rejected.",
                 "evidence" => String.duplicate("x", 10_001)
               })

      assert %{evidence: [_message]} = errors_on(changeset)
    end

    test "records when verification was agent draft, human edited", %{scan: scan} do
      assert {:ok, scan} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "confirmed",
                 "provenance" => "hybrid",
                 "notes" => "Agent located the path; I reproduced the authorization bypass."
               })

      assert [confirmation] = scan.confirmations
      assert confirmation.provenance == "hybrid"
    end

    test "agent-only verdicts are retained but never count toward quorum", %{scan: scan} do
      assert {:ok, scan} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "confirmed",
                 "provenance" => "agent",
                 "notes" =>
                   "The agent agreed with the report, but no person reproduced its evidence."
               })

      assert [%{provenance: "agent"}] = scan.confirmations
      assert scan.confirmations_count == 0
      refute Scans.Scan.verified?(scan)
    end

    test "verification evidence is required", %{scan: scan} do
      assert {:error, changeset} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "confirmed",
                 "notes" => "too short"
               })

      assert "should be at least 20 character(s)" in errors_on(changeset).notes
    end

    test "ordinary accounts cannot cast state-changing verdicts", %{scan: scan} do
      assert {:error, :unauthorized} =
               Scans.record_confirmation(scan, account_fixture(), %{
                 "verdict" => "confirmed",
                 "notes" => "Being authenticated alone cannot create a trusted verification."
               })
    end

    test "a dispute nets a verification back out", %{repository: repository, scan: scan} do
      scan = confirmation_fixture(scan, reviewer_account_fixture(), "confirmed")
      scan = confirmation_fixture(scan, reviewer_account_fixture(), "confirmed")
      assert Scans.Scan.verified?(scan)

      assert {:ok, scan} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "disputed",
                 "notes" => "The described source is unreachable after tracing every caller."
               })

      assert scan.confirmations_count == 2
      assert scan.disputes_count == 1
      refute Scans.Scan.verified?(scan)

      repository = Repositories.get_github_repository(repository.owner, repository.name)
      assert repository.verified_findings_count == 0
    end

    test "verifying a clean scan leaves verified findings at zero", %{
      repository: repository,
      submitter: submitter
    } do
      clean_scan = scan_fixture(repository, submitter)
      scan = confirmation_fixture(clean_scan, reviewer_account_fixture())
      scan = confirmation_fixture(scan, reviewer_account_fixture())

      assert Scans.Scan.verified?(scan)

      repository = Repositories.get_github_repository(repository.owner, repository.name)
      assert repository.verified_findings_count == 0
      assert repository.status == "findings"
    end

    test "submitters cannot confirm their own scan", %{submitter: submitter, scan: scan} do
      submitter = reviewer_account(submitter)
      forged_scan = %{scan | submitted_by_id: -1, repository_id: scan.repository_id + 10_000}

      assert {:error, :conflict_of_interest} =
               Scans.record_confirmation(forged_scan, submitter, %{
                 "verdict" => "confirmed",
                 "notes" => "This deliberately long note cannot bypass the independence rule."
               })
    end

    test "authorization uses the canonical locked scan, not caller-supplied relationships", %{
      scan: scan
    } do
      reviewer = reviewer_account_fixture()
      wrong_repository_id = scan.repository_id + 10_000

      scope =
        Scope.for_account(reviewer,
          token_scopes: ["reviews:verify"],
          token_repository_id: wrong_repository_id
        )

      forged_scan = %{scan | repository_id: wrong_repository_id, submitted_by_id: -1}

      assert {:error, :unauthorized} =
               Scans.record_confirmation(scope, forged_scan, %{
                 "verdict" => "confirmed",
                 "notes" => "A forged relationship must not bypass repository-bound credentials."
               })
    end

    test "each account gets one verdict per scan", %{scan: scan} do
      confirmer = reviewer_account_fixture()
      confirmation_fixture(scan, confirmer)

      assert {:error, changeset} =
               Scans.record_confirmation(scan, confirmer, %{
                 "verdict" => "disputed",
                 "notes" => "A second opinion from one identity must not create another vote."
               })

      assert "you already recorded a verdict on this scan" in errors_on(changeset).scan_id
    end

    test "rejects unknown verdicts", %{scan: scan} do
      assert {:error, changeset} =
               Scans.record_confirmation(scan, reviewer_account_fixture(), %{
                 "verdict" => "maybe",
                 "notes" => "This evidence is long enough that verdict validation is isolated."
               })

      assert "is invalid" in errors_on(changeset).verdict
    end

    test "broadcasts the updated scan and repository record", %{
      repository: repository,
      scan: scan
    } do
      Scans.subscribe(repository.id)
      Repositories.subscribe()

      {:ok, _scan} =
        Scans.record_confirmation(scan, reviewer_account_fixture(), %{
          "verdict" => "confirmed",
          "notes" => "Independently reproduced the reported behavior at the pinned commit."
        })

      scan_id = scan.id
      assert_received {:scan_updated, %{id: ^scan_id, confirmations_count: 1}}
      assert_received {:repository_record_updated, %{verified_findings_count: 0}}
    end
  end

  describe "canonical finding checks" do
    setup do
      submitter = github_account_fixture()
      repository = github_repository_fixture(submitter)

      scan =
        scan_fixture(repository, submitter, %{
          "findings_json" => findings_json_fixture(1)
        })

      [occurrence] = scan.findings
      canonical = Repo.get!(CanonicalFinding, occurrence.canonical_finding_id)
      %{submitter: submitter, repository: repository, scan: scan, canonical: canonical}
    end

    test "checks are per finding and require independent quorum", context do
      attrs = %{
        "commit_sha" => context.scan.commit_sha,
        "verdict" => "confirmed",
        "provenance" => "human",
        "notes" => "Independently reproduced this exact canonical finding at the pinned commit."
      }

      assert {:error, :conflict_of_interest} =
               FindingMemory.record_check(
                 Scope.for_account(reviewer_account(context.submitter)),
                 context.repository,
                 context.canonical.public_id,
                 attrs
               )

      assert {:ok, _check, first} =
               FindingMemory.record_check(
                 Scope.for_account(reviewer_account_fixture()),
                 context.repository,
                 context.canonical.public_id,
                 attrs
               )

      assert first.status == "open"
      assert first.confirmations_count == 1

      assert {:ok, _check, verified} =
               FindingMemory.record_check(
                 Scope.for_account(reviewer_account_fixture()),
                 context.repository,
                 context.canonical.public_id,
                 attrs
               )

      assert verified.status == "verified"
      assert verified.confirmations_count == 2
      assert Repo.get!(Scan, context.scan.id).verified_at

      repository =
        Repositories.get_github_repository(context.repository.owner, context.repository.name)

      assert repository.open_findings_count == 1
      assert repository.verified_findings_count == 1
    end

    test "agent-only checks are retained without creating verification", context do
      attrs = %{
        "commit_sha" => context.scan.commit_sha,
        "verdict" => "confirmed",
        "provenance" => "agent",
        "notes" => "A second agent independently traced the same vulnerable data flow."
      }

      assert {:ok, _check, canonical} =
               FindingMemory.record_check(
                 Scope.for_account(reviewer_account_fixture()),
                 context.repository,
                 context.canonical.public_id,
                 attrs
               )

      assert canonical.status == "open"
      assert canonical.confirmations_count == 0
      refute Repo.get!(Scan, context.scan.id).verified_at
    end

    test "platform reviewers count without being moderators", context do
      reviewer =
        account_fixture()
        |> Tarakan.Accounts.Account.authorization_changeset(%{
          state: "active",
          platform_role: "member",
          trust_tier: "reviewer"
        })
        |> Repo.update!()

      attrs = %{
        "commit_sha" => context.scan.commit_sha,
        "verdict" => "confirmed",
        "provenance" => "human",
        "notes" => "Independently reproduced the canonical finding through the web workflow."
      }

      assert {:ok, _check, canonical} =
               FindingMemory.record_check(
                 Scope.for_account(reviewer),
                 context.repository,
                 context.canonical.public_id,
                 attrs
               )

      assert canonical.confirmations_count == 1
      assert canonical.status == "open"
    end

    test "two independent fixed checks close the canonical finding", context do
      attrs = %{
        "commit_sha" => context.scan.commit_sha,
        "verdict" => "fixed",
        "provenance" => "human",
        "notes" => "Confirmed the vulnerable behavior is absent at this pinned commit."
      }

      for _index <- 1..2 do
        assert {:ok, _check, _canonical} =
                 FindingMemory.record_check(
                   Scope.for_account(reviewer_account_fixture()),
                   context.repository,
                   context.canonical.public_id,
                   attrs
                 )
      end

      canonical = Repo.get!(CanonicalFinding, context.canonical.id)
      assert canonical.status == "fixed"
      assert Repo.get!(Scan, context.scan.id).verified_at

      repository =
        Repositories.get_github_repository(context.repository.owner, context.repository.name)

      assert repository.open_findings_count == 0
      assert repository.verified_findings_count == 0

      recurrence =
        scan_fixture(context.repository, account_fixture(), %{
          "commit_sha" => random_commit_sha(),
          "findings_json" => findings_json_fixture(1)
        })

      assert [occurrence] = recurrence.findings
      assert occurrence.canonical_finding_id == canonical.id
      assert occurrence.disposition == "regression"
      assert Repo.get!(CanonicalFinding, canonical.id).status == "open"
    end
  end

  describe "moderation and disclosure" do
    setup do
      submitter = github_account_fixture()
      repository = github_repository_fixture(submitter)
      scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(2)})

      %{repository: repository, submitter: submitter, scan: scan}
    end

    test "acceptance requires quorum and a qualified moderator", %{scan: scan} do
      attrs = moderation_attributes(%{"visibility" => "public_summary"})

      assert {:error, :verification_required} =
               Scans.accept_scan(Scope.for_account(moderator_account_fixture()), scan, attrs)

      verified_scan = verify_scan(scan)

      assert {:error, :unauthorized} =
               Scans.accept_scan(Scope.for_account(account_fixture()), verified_scan, attrs)
    end

    test "a verified repository steward may moderate its repository", %{
      repository: repository,
      scan: scan
    } do
      steward = account_fixture()

      assert {:ok, membership} =
               Repositories.propose_repository_membership(
                 Scope.for_account(steward),
                 repository,
                 steward,
                 %{role: "steward"}
               )

      assert {:ok, _verified_membership} =
               Repositories.set_repository_membership_status(
                 Scope.for_account(moderator_account_fixture()),
                 membership,
                 :verified
               )

      scope = Tarakan.Accounts.scope_for_account(steward)

      assert {:ok, accepted} =
               Scans.accept_scan(
                 scope,
                 verify_scan(scan),
                 moderation_attributes(%{"visibility" => "public_summary"})
               )

      assert accepted.review_status == "accepted"
    end

    test "a submitter cannot moderate through a forged scan struct", %{
      submitter: submitter,
      scan: scan
    } do
      submitter = moderator_account(submitter)
      verified_scan = verify_scan(scan)

      forged_scan = %{
        verified_scan
        | submitted_by_id: -1,
          repository_id: verified_scan.repository_id + 10_000
      }

      assert {:error, :conflict_of_interest} =
               Scans.accept_scan(
                 Scope.for_account(submitter),
                 forged_scan,
                 moderation_attributes(%{"visibility" => "public"})
               )
    end

    test "public summaries expose aggregates but redact raw evidence", %{
      repository: repository,
      scan: scan
    } do
      scan = verify_scan(scan)

      assert {:ok, accepted} =
               Scans.accept_scan(
                 Scope.for_account(moderator_account_fixture()),
                 scan,
                 moderation_attributes(%{"visibility" => "public_summary"})
               )

      assert accepted.review_status == "accepted"
      assert accepted.visibility == "public_summary"

      assert {:ok, _accepted} =
               Scans.update_visibility(
                 Scope.for_account(moderator_account_fixture()),
                 accepted,
                 "public_summary",
                 moderation_attributes()
               )

      assert Repo.all(
               from event in Event,
                 where: event.subject_id == ^scan.id,
                 order_by: [asc: event.id],
                 select: event.action
             ) == [
               "review_submitted",
               "review_verdict_recorded",
               "review_verdict_recorded",
               "review_moderated",
               "review_moderated"
             ]

      assert [public_scan] = Scans.list_scans(repository)
      assert public_scan.id == scan.id
      assert public_scan.findings_count == 2
      assert public_scan.findings == []
      assert public_scan.confirmations == []
      assert public_scan.notes == nil
      refute public_scan.details_visible

      repository = Repositories.get_github_repository(repository.owner, repository.name)
      assert repository.scan_count == 1
      assert repository.open_findings_count == 2
      assert repository.verified_findings_count == 2
      assert repository.status == "findings"
    end

    test "finding lookup inherits restricted and full-disclosure policy", %{
      repository: repository,
      submitter: submitter,
      scan: scan
    } do
      moderator_scope = Scope.for_account(moderator_account_fixture())

      {:ok, accepted} =
        Scans.accept_scan(moderator_scope, verify_scan(scan), moderation_attributes())

      {:ok, summary} =
        Scans.update_visibility(
          moderator_scope,
          accepted,
          "public_summary",
          moderation_attributes()
        )

      finding_id = hd(summary.findings).id
      finding_public_id = hd(summary.findings).public_id
      assert {:error, :not_found} = Scans.get_finding(nil, finding_public_id)

      assert {:ok, {%{id: scan_id}, %{id: ^finding_id}}} =
               Scans.get_finding(Scope.for_account(submitter), finding_public_id)

      assert scan_id == scan.id

      repository
      |> Tarakan.Repositories.Repository.participation_changeset(%{
        participation_mode: "maintainer_verified"
      })
      |> Repo.update!()

      {:ok, _full} =
        Scans.update_visibility(
          moderator_scope,
          summary,
          "public",
          moderation_attributes(%{"sensitive_data_reviewed" => "true"})
        )

      assert {:ok, {%{id: ^scan_id}, %{id: ^finding_id}}} =
               Scans.get_finding(nil, finding_public_id)

      assert {:error, :not_found} = Scans.get_finding(nil, "not-an-id")
    end

    test "full disclosure exposes accepted evidence", %{repository: repository, scan: scan} do
      moderator = moderator_account_fixture()

      repository
      |> Tarakan.Repositories.Repository.participation_changeset(%{
        participation_mode: "maintainer_verified"
      })
      |> Repo.update!()

      {:ok, accepted} =
        Scans.accept_scan(
          Scope.for_account(moderator),
          verify_scan(scan),
          moderation_attributes()
        )

      assert Scans.list_scans(repository) == []

      assert {:ok, disclosed} =
               Scans.update_visibility(
                 Scope.for_account(moderator),
                 accepted,
                 "public",
                 moderation_attributes(%{"sensitive_data_reviewed" => "true"})
               )

      assert disclosed.visibility == "public"

      assert [%{findings: [_, _], details_visible: true} = public] =
               Scans.list_scans(repository)

      assert Enum.all?(public.confirmations, &is_nil(&1.notes))
      assert public.moderation_notes == nil
    end

    test "a later accepted empty review cannot clear an accepted finding report", %{
      repository: repository,
      scan: scan
    } do
      moderator = moderator_account_fixture()
      scope = Scope.for_account(moderator)

      assert {:ok, _accepted} =
               Scans.accept_scan(
                 scope,
                 verify_scan(scan),
                 moderation_attributes(%{"visibility" => "public_summary"})
               )

      first = Scans.get_scan(scope, scan.id) |> elem(1)

      assert {:ok, _public} =
               Scans.update_visibility(scope, first, "public_summary", moderation_attributes())

      clean_scan = scan_fixture(repository, account_fixture()) |> verify_scan()

      assert {:ok, _accepted_clean} =
               Scans.accept_scan(
                 scope,
                 clean_scan,
                 moderation_attributes(%{"visibility" => "public_summary"})
               )

      clean = Scans.get_scan(scope, clean_scan.id) |> elem(1)

      assert {:ok, _public} =
               Scans.update_visibility(scope, clean, "public_summary", moderation_attributes())

      repository = Repositories.get_github_repository(repository.owner, repository.name)
      assert repository.scan_count == 2
      assert repository.open_findings_count == 2
      assert repository.status == "findings"
    end

    test "losing verification quorum automatically contests without restricting", %{
      repository: repository,
      scan: scan
    } do
      {:ok, accepted} =
        Scans.accept_scan(
          Scope.for_account(moderator_account_fixture()),
          verify_scan(scan),
          moderation_attributes(%{"visibility" => "public"})
        )

      {:ok, accepted} =
        Scans.update_visibility(
          Scope.for_account(moderator_account_fixture()),
          accepted,
          "public_summary",
          moderation_attributes()
        )

      assert {:ok, contested} =
               Scans.record_confirmation(accepted, reviewer_account_fixture(), %{
                 "verdict" => "disputed",
                 "notes" => "The reported sink is not reachable from the stated untrusted source."
               })

      assert contested.review_status == "contested"
      assert contested.visibility == "public_summary"
      refute Scans.Scan.verified?(contested)
      assert [%{id: listed_id}] = Scans.list_scans(repository)
      assert listed_id == scan.id

      repository = Repositories.get_github_repository(repository.owner, repository.name)
      assert repository.status == "findings"
      assert repository.open_findings_count == 2
      assert repository.verified_findings_count == 0
    end

    test "moderation decisions require a reason and supporting evidence", %{scan: scan} do
      assert {:error, changeset} =
               Scans.accept_scan(
                 Scope.for_account(moderator_account_fixture()),
                 verify_scan(scan),
                 %{"visibility" => "public_summary"}
               )

      assert "can't be blank" in errors_on(changeset).moderation_reason
      assert "can't be blank" in errors_on(changeset).moderation_notes
    end

    test "rejection is a status label and leaves visibility alone", %{scan: scan} do
      scope = Scope.for_account(moderator_account_fixture())

      assert {:ok, rejected} =
               Scans.reject_scan(
                 scope,
                 scan,
                 moderation_attributes(%{"visibility" => "public"})
               )

      assert rejected.review_status == "rejected"
      assert rejected.visibility == "public"

      assert {:ok, restricted} =
               Scans.update_visibility(scope, rejected, "restricted", moderation_attributes())

      assert restricted.visibility == "restricted"
    end
  end

  defp verify_scan(scan) do
    scan = confirmation_fixture(scan, reviewer_account_fixture())
    confirmation_fixture(scan, reviewer_account_fixture())
  end

  defp moderation_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        "visibility" => "restricted",
        "moderation_reason" => "evidence_reviewed",
        "moderation_notes" =>
          "Two independent reviewers supplied reproducible evidence for the pinned commit."
      },
      overrides
    )
  end
end
