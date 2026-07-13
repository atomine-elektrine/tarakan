defmodule Tarakan.ModerationTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, ApiCredentials, Scope}
  alias Tarakan.Moderation
  alias Tarakan.Moderation.{Action, Appeal}
  alias Tarakan.Moderation.Case, as: ModerationCase
  alias Tarakan.Repositories
  alias Tarakan.Repositories.{Repository, RepositoryMembership}
  alias Tarakan.Scans
  alias Tarakan.Scans.Scan
  alias Tarakan.Work.{Contribution, ReviewTask}

  describe "report/2" do
    test "is idempotent per open subject even when a retry changes its reason" do
      reporter = account_fixture()
      subject = account_fixture()

      assert {:ok, first} = report_account(reporter, subject)

      assert {:ok, retry} =
               Moderation.report(Scope.for_account(reporter), %{
                 "subject_type" => "account",
                 "subject_id" => subject.id,
                 "reason" => "harassment",
                 "description" => "A retry must not create another queue entry for this subject."
               })

      assert retry.id == first.id
      assert Repo.aggregate(ModerationCase, :count) == 1
    end

    test "enforces the probation quota across distinct subjects" do
      reporter = account_fixture()

      for _index <- 1..5 do
        assert {:ok, %ModerationCase{}} = report_account(reporter, account_fixture())
      end

      assert {:error, :rate_limited} = report_account(reporter, account_fixture())
    end

    test "does not expose moderation reporting to client credentials" do
      reporter = account_fixture() |> set_authorization(%{state: "active"})
      repository = repository_fixture()

      {:ok, _token, credential} =
        ApiCredentials.create(reporter, %{
          name: "repository tasks",
          scopes: ["tasks:read"],
          repository_id: repository.id
        })

      credential_scope =
        Scope.for_account(reporter,
          token_id: credential.id,
          token_scopes: credential.scopes,
          token_repository_id: repository.id,
          authentication_method: :api_credential
        )

      assert {:error, :unauthorized} = report_repository(credential_scope, repository)
    end

    test "does not disclose or accept reports against restricted reviews the caller cannot see" do
      submitter = account_fixture()
      stranger = account_fixture()
      repository = repository_fixture()
      scan = restricted_scan_fixture(repository, submitter)

      attrs = report_attrs("scan", scan.id)

      assert {:error, :subject_not_found} =
               Moderation.report(Scope.for_account(stranger), attrs)

      assert {:ok, %ModerationCase{subject_owner_id: owner_id}} =
               Moderation.report(Scope.for_account(submitter), attrs)

      assert owner_id == submitter.id
    end

    test "does not treat an accepted but undisclosed contribution as public" do
      repository = repository_fixture()
      creator = account_fixture()
      contributor = account_fixture()
      stranger = account_fixture()

      task =
        Repo.insert!(%ReviewTask{
          repository_id: repository.id,
          created_by_id: creator.id,
          commit_sha: String.duplicate("b", 40),
          kind: "code_review",
          capability: "human",
          title: "Review the authorization boundary",
          description: "Trace the authorization boundary and record reproducible evidence.",
          status: "accepted",
          visibility: "restricted"
        })

      contribution =
        Repo.insert!(%Contribution{
          review_task_id: task.id,
          account_id: contributor.id,
          version: 1,
          provenance: "human",
          summary: "The review is complete.",
          evidence: "Reproduced the authorization behavior against the pinned commit."
        })

      attrs = report_attrs("contribution", contribution.id)

      assert {:error, :subject_not_found} =
               Moderation.report(Scope.for_account(stranger), attrs)

      disclosed_at = DateTime.utc_now()

      _disclosed =
        task
        |> Ecto.Changeset.change(
          visibility: "public_summary",
          disclosed_at: disclosed_at,
          disclosed_by_id: creator.id
        )
        |> Repo.update!()

      assert {:ok, %ModerationCase{}} =
               Moderation.report(Scope.for_account(stranger), attrs)

      Repository
      |> Repo.get!(task.repository_id)
      |> Repository.listing_changeset(%{listing_status: "quarantined"})
      |> Repo.update!()

      assert {:error, :subject_not_found} =
               Moderation.report(Scope.for_account(account_fixture()), attrs)
    end

    test "malformed subject identifiers return an error instead of raising" do
      scope = Scope.for_account(account_fixture())

      for subject_id <- [nil, [], %{}, -1, "1 trailing"] do
        assert {:error, :subject_not_found} =
                 Moderation.report(scope, report_attrs("account", subject_id))
      end

      assert {:error, :invalid_report} = Moderation.report(scope, subject_type: "account")
    end
  end

  describe "moderator authorization and transitions" do
    test "only a fresh active moderator may inspect or claim the queue" do
      reporter = account_fixture()
      case_record = report_account!(reporter, account_fixture())
      member = account_fixture()

      assert {:error, :unauthorized} = Moderation.list_open(Scope.for_account(member))
      assert {:error, :unauthorized} = Moderation.assign(Scope.for_account(member), case_record)

      moderator = moderator_fixture()
      stale_scope = Scope.for_account(moderator)
      _suspended = set_authorization(moderator, %{state: "suspended"})

      assert {:error, :unauthorized} = Moderation.list_open(stale_scope)
      assert {:error, :unauthorized} = Moderation.assign(stale_scope, case_record)
    end

    test "reporters and subject owners cannot moderate their own case" do
      subject = account_fixture()
      reporter_moderator = moderator_fixture()
      reporter_case = report_account!(reporter_moderator, subject)

      assert {:error, :conflict_of_interest} =
               Moderation.assign(Scope.for_account(reporter_moderator), reporter_case)

      reporter = account_fixture()
      owner_moderator = moderator_fixture()
      owner_case = report_account!(reporter, owner_moderator)

      assert {:error, :conflict_of_interest} =
               Moderation.assign(Scope.for_account(owner_moderator), owner_case)
    end

    test "only the assignee can decide, and exact retries do not duplicate actions" do
      case_record = report_account!(account_fixture(), account_fixture())
      assignee = moderator_fixture()
      other_moderator = moderator_fixture()
      resolution = "The submitted evidence demonstrates a policy violation."

      assert {:ok, assigned} = Moderation.assign(Scope.for_account(assignee), case_record)
      assert assigned.status == "in_review"

      assert {:error, :not_assigned} =
               Moderation.resolve(
                 Scope.for_account(other_moderator),
                 assigned,
                 "resolved",
                 resolution
               )

      assert {:ok, resolved} =
               Moderation.resolve(Scope.for_account(assignee), assigned, "resolved", resolution)

      assert resolved.status == "resolved"
      assert resolved.resolved_by_id == assignee.id

      assert {:ok, retried} =
               Moderation.resolve(Scope.for_account(assignee), assigned, "resolved", resolution)

      assert retried.id == resolved.id

      assert Repo.aggregate(
               from(action in Action, where: action.moderation_case_id == ^resolved.id),
               :count
             ) == 3

      assert Repo.aggregate(
               from(action in Action,
                 where:
                   action.moderation_case_id == ^resolved.id and action.action == "quarantine"
               ),
               :count
             ) == 1

      assert {:error, :invalid_transition} =
               Moderation.resolve(
                 Scope.for_account(assignee),
                 assigned,
                 "resolved",
                 "A materially different reason must not rewrite the original decision."
               )
    end

    test "administrators can recover a case abandoned by another moderator" do
      case_record = report_account!(account_fixture(), account_fixture())
      moderator = moderator_fixture()
      admin = admin_fixture()

      assert {:ok, assigned} = Moderation.assign(Scope.for_account(moderator), case_record)
      assert {:ok, reassigned} = Moderation.assign(Scope.for_account(admin), assigned)
      assert reassigned.assigned_to_id == admin.id

      assert Enum.count(reassigned.actions, &(&1.action == "assign")) == 2
    end

    test "the moderation queue is bounded and can request a smaller page" do
      for _index <- 1..3 do
        report_account!(account_fixture(), account_fixture())
      end

      assert {:ok, cases} = Moderation.list_open(Scope.for_account(moderator_fixture()), limit: 1)
      assert length(cases) == 1
    end
  end

  describe "resolved-case containment" do
    test "a moderator can restrict an ordinary account without changing role or trust" do
      subject =
        account_fixture()
        |> set_authorization(%{
          state: "active",
          platform_role: "member",
          trust_tier: "contributor"
        })

      _resolved =
        resolve_case!(
          report_account!(account_fixture(), subject),
          moderator_fixture(),
          "resolved",
          valid_resolution()
        )

      contained = Repo.get!(Account, subject.id)
      assert contained.state == "restricted"
      assert contained.platform_role == "member"
      assert contained.trust_tier == "contributor"
    end

    test "only an administrator can contain another administrator account" do
      subject =
        account_fixture()
        |> set_authorization(%{
          state: "active",
          platform_role: "admin",
          trust_tier: "reviewer"
        })

      case_record = report_account!(account_fixture(), subject)
      moderator = moderator_fixture()

      assert {:ok, assigned} = Moderation.assign(Scope.for_account(moderator), case_record)

      assert {:error, :unauthorized} =
               Moderation.resolve(
                 Scope.for_account(moderator),
                 assigned,
                 "resolved",
                 valid_resolution()
               )

      administrator = admin_fixture()
      assert {:ok, reassigned} = Moderation.assign(Scope.for_account(administrator), assigned)

      assert {:ok, resolved} =
               Moderation.resolve(
                 Scope.for_account(administrator),
                 reassigned,
                 "resolved",
                 valid_resolution()
               )

      contained = Repo.get!(Account, subject.id)
      assert contained.state == "restricted"
      assert contained.platform_role == "admin"
      assert contained.trust_tier == "reviewer"

      assert Enum.any?(resolved.actions, fn action ->
               action.action == "quarantine" and
                 action.metadata["remedy"] == "account_restricted"
             end)
    end

    test "a repository stays paused and quarantined until a moderator or upheld appeal clears the hold" do
      repository =
        repository_fixture()
        |> Repository.listing_changeset(%{listing_status: "listed"})
        |> Repo.update!()

      steward = account_fixture() |> set_authorization(%{state: "active"})
      verifier = moderator_fixture()

      Repo.insert!(%RepositoryMembership{
        repository_id: repository.id,
        account_id: steward.id,
        role: "steward",
        status: "verified",
        verified_at: DateTime.utc_now(),
        verified_by_account_id: verifier.id
      })

      resolved =
        report_repository(Scope.for_account(account_fixture()), repository)
        |> then(fn {:ok, case_record} ->
          resolve_case!(case_record, moderator_fixture(), "resolved", valid_resolution())
        end)

      contained = Repo.get!(Repository, repository.id)
      assert contained.participation_mode == "paused"
      assert contained.listing_status == "quarantined"

      steward_scope = Accounts.scope_for_account(steward)

      assert {:error, :unauthorized} =
               Repositories.update_participation_mode(steward_scope, contained, %{
                 participation_mode: "community"
               })

      assert {:error, :unauthorized} =
               Repositories.update_listing_status(steward_scope, contained, "listed")

      platform_moderator = moderator_fixture()

      assert {:ok, temporarily_restored} =
               Repositories.update_participation_mode(
                 Scope.for_account(platform_moderator),
                 contained,
                 %{participation_mode: "community"}
               )

      assert {:ok, paused_again} =
               Repositories.update_participation_mode(
                 Scope.for_account(platform_moderator),
                 temporarily_restored,
                 %{participation_mode: "paused"}
               )

      assert {:ok, appeal} =
               Moderation.appeal(steward_scope, resolved, %{
                 "reason" =>
                   "The reported public material was removed and the repository is ready for review."
               })

      assert {:ok, _decision} =
               Moderation.decide_appeal(
                 Scope.for_account(moderator_fixture()),
                 appeal,
                 "upheld",
                 "Independent review confirms the reported material is no longer exposed."
               )

      assert {:ok, community_repository} =
               Repositories.update_participation_mode(steward_scope, paused_again, %{
                 participation_mode: "community"
               })

      assert community_repository.listing_status == "quarantined"

      assert {:ok, listed_repository} =
               Repositories.update_listing_status(
                 steward_scope,
                 community_repository,
                 "listed"
               )

      assert listed_repository.listing_status == "listed"
    end

    test "a scan hold blocks repository stewards but permits platform moderation" do
      repository = repository_fixture()
      submitter = account_fixture()
      scan = restricted_scan_fixture(repository, submitter)
      scan = confirmation_fixture(scan, reviewer_account_fixture())
      scan = confirmation_fixture(scan, reviewer_account_fixture())
      steward = account_fixture() |> set_authorization(%{state: "active"})

      Repo.insert!(%RepositoryMembership{
        repository_id: repository.id,
        account_id: steward.id,
        role: "steward",
        status: "verified",
        verified_at: DateTime.utc_now(),
        verified_by_account_id: moderator_fixture().id
      })

      case_record =
        Moderation.report(Scope.for_account(submitter), report_attrs("scan", scan.id))
        |> then(fn {:ok, case_record} -> case_record end)

      _resolved =
        resolve_case!(case_record, moderator_fixture(), "resolved", valid_resolution())

      contained_scan = Repo.get!(Scan, scan.id)
      assert contained_scan.review_status == "contested"
      assert contained_scan.visibility == "restricted"

      moderation_attrs = %{
        "moderation_reason" => "independent_evidence_reviewed",
        "moderation_notes" =>
          "The evidence and verification record were independently reviewed in full."
      }

      assert {:error, :unauthorized} =
               Scans.accept_scan(
                 Accounts.scope_for_account(steward),
                 contained_scan,
                 moderation_attrs
               )

      assert {:ok, restored_scan} =
               Scans.accept_scan(
                 Scope.for_account(moderator_fixture()),
                 contained_scan,
                 moderation_attrs
               )

      assert restored_scan.review_status == "accepted"
      assert restored_scan.visibility == "restricted"
    end
  end

  describe "case visibility" do
    test "participant reads do not preload private identities or internal action history" do
      reporter = account_fixture()
      subject = account_fixture()
      case_record = report_account!(reporter, subject)

      assert {:ok, visible} = Moderation.get_case(Scope.for_account(reporter), case_record.id)
      refute Ecto.assoc_loaded?(visible.reporter)
      refute Ecto.assoc_loaded?(visible.subject_owner)
      refute Ecto.assoc_loaded?(visible.actions)
      assert Ecto.assoc_loaded?(visible.appeals)
      assert visible.appeals == []

      assert {:ok, _visible_to_subject} =
               Moderation.get_case(Scope.for_account(subject), case_record.id)

      assert {:error, :not_found} =
               Moderation.get_case(Scope.for_account(account_fixture()), case_record.id)

      assert {:error, :not_found} =
               Moderation.get_case(
                 Scope.for_account(account_fixture()),
                 case_record.id + 1_000_000
               )
    end

    test "active moderators receive case history without loading account secrets" do
      case_record = report_account!(account_fixture(), account_fixture())

      assert {:ok, visible} =
               Moderation.get_case(Scope.for_account(moderator_fixture()), case_record.id)

      refute Ecto.assoc_loaded?(visible.reporter)
      refute Ecto.assoc_loaded?(visible.subject_owner)
      assert Ecto.assoc_loaded?(visible.actions)
    end

    test "participant moderation records remain hidden from client credentials" do
      reporter = account_fixture() |> set_authorization(%{state: "active"})
      repository = repository_fixture()

      {:ok, case_record} = report_repository(Scope.for_account(reporter), repository)

      {:ok, _token, credential} =
        ApiCredentials.create(reporter, %{
          name: "repository tasks",
          scopes: ["tasks:read"],
          repository_id: repository.id
        })

      credential_scope =
        Scope.for_account(reporter,
          token_id: credential.id,
          token_scopes: credential.scopes,
          token_repository_id: repository.id,
          authentication_method: :api_credential
        )

      assert {:error, :not_found} = Moderation.get_case(credential_scope, case_record.id)
    end
  end

  describe "appeals" do
    test "an independent moderator can uphold an appeal exactly once" do
      reporter = account_fixture()
      subject = account_fixture()
      resolver = moderator_fixture()
      appeal_moderator = moderator_fixture()
      resolution = "The submitted content violates the published evidence rules."

      resolved =
        resolve_case!(report_account!(reporter, subject), resolver, "resolved", resolution)

      assert {:ok, appeal} =
               Moderation.appeal(Scope.for_account(subject), resolved, %{
                 "reason" =>
                   "The cited evidence belongs to a different commit and should be reconsidered."
               })

      assert {:error, :conflict_of_interest} =
               Moderation.decide_appeal(
                 Scope.for_account(resolver),
                 appeal,
                 "upheld",
                 "The appeal establishes that the original decision used the wrong commit."
               )

      decision_reason =
        "The appeal establishes that the original decision used the wrong commit."

      assert {:ok, decided} =
               Moderation.decide_appeal(
                 Scope.for_account(appeal_moderator),
                 appeal,
                 "upheld",
                 decision_reason
               )

      assert decided.status == "upheld"
      assert Repo.get!(ModerationCase, resolved.id).status == "overturned"

      assert {:ok, retry} =
               Moderation.decide_appeal(
                 Scope.for_account(appeal_moderator),
                 appeal,
                 "upheld",
                 decision_reason
               )

      assert retry.id == decided.id

      assert Repo.aggregate(
               from(action in Action,
                 where:
                   action.moderation_case_id == ^resolved.id and
                     action.action == "appeal_upheld"
               ),
               :count
             ) == 1

      assert {:ok, same_appeal} =
               Moderation.appeal(Scope.for_account(subject), resolved, %{
                 "reason" => "A repeated submission returns the existing appeal without mutation."
               })

      assert same_appeal.id == decided.id
    end

    test "dismissed reports are not appealable by the subject" do
      subject = account_fixture()

      dismissed =
        resolve_case!(
          report_account!(account_fixture(), subject),
          moderator_fixture(),
          "dismissed",
          "The report does not contain evidence of a policy violation."
        )

      assert {:error, :not_appealable} =
               Moderation.appeal(Scope.for_account(subject), dismissed, %{
                 "reason" => "There is no adverse moderation decision for the subject to appeal."
               })
    end

    test "a verified repository steward may appeal for a repository" do
      repository = repository_fixture()
      reporter = account_fixture()
      steward = account_fixture()
      verifier = moderator_fixture()

      Repo.insert!(%RepositoryMembership{
        repository_id: repository.id,
        account_id: steward.id,
        role: "steward",
        status: "verified",
        verified_at: DateTime.utc_now(),
        verified_by_account_id: verifier.id
      })

      {:ok, case_record} = report_repository(Scope.for_account(reporter), repository)

      resolved =
        resolve_case!(
          case_record,
          moderator_fixture(),
          "resolved",
          "The repository page contains unsafe disclosure material."
        )

      assert {:ok, %Appeal{appellant_id: appellant_id}} =
               Moderation.appeal(Accounts.scope_for_account(steward), resolved, %{
                 "reason" =>
                   "The verified maintainers have removed the material and request review."
               })

      assert appellant_id == steward.id
    end
  end

  describe "database integrity" do
    test "moderation actions are append-only" do
      case_record =
        report_account!(account_fixture(), account_fixture())
        |> then(&resolve_case!(&1, moderator_fixture(), "resolved", valid_resolution()))

      action =
        Repo.one!(
          from action in Action,
            where: action.moderation_case_id == ^case_record.id,
            order_by: [asc: action.id],
            limit: 1
        )

      assert_raise Postgrex.Error, ~r/moderation_actions are append-only/, fn ->
        Repo.update_all(from(candidate in Action, where: candidate.id == ^action.id),
          set: [reason: "A rewritten history entry must be rejected by the database."]
        )
      end
    end

    test "case and appeal history cannot be deleted" do
      subject = account_fixture()

      resolved =
        resolve_case!(
          report_account!(account_fixture(), subject),
          moderator_fixture(),
          "resolved",
          valid_resolution()
        )

      {:ok, appeal} =
        Moderation.appeal(Scope.for_account(subject), resolved, %{
          "reason" => "This sufficiently detailed appeal exists to test historical preservation."
        })

      assert_raise Postgrex.Error, ~r/moderation history cannot be deleted/, fn ->
        Repo.delete!(appeal)
      end
    end

    test "repository deletion preserves its moderation record" do
      repository = repository_fixture()
      reporter = account_fixture()

      case_record =
        Repo.insert!(%ModerationCase{
          reporter_id: reporter.id,
          repository_id: repository.id,
          subject_type: "repository",
          subject_id: repository.id,
          reason: "fabricated_evidence",
          description: "This direct fixture isolates the moderation history foreign key behavior."
        })

      Repo.delete!(repository)

      preserved = Repo.get!(ModerationCase, case_record.id)
      assert is_nil(preserved.repository_id)
      assert preserved.subject_type == "repository"
      assert preserved.subject_id == repository.id
    end

    test "the database rejects impossible resolution state" do
      case_record = report_account!(account_fixture(), account_fixture())

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(from(candidate in ModerationCase, where: candidate.id == ^case_record.id),
          set: [status: "resolved"]
        )
      end
    end
  end

  defp report_account(reporter, subject) do
    Moderation.report(Scope.for_account(reporter), report_attrs("account", subject.id))
  end

  defp report_account!(reporter, subject) do
    {:ok, case_record} = report_account(reporter, subject)
    case_record
  end

  defp report_repository(scope, repository) do
    Moderation.report(scope, report_attrs("repository", repository.id))
  end

  defp report_attrs(type, id) do
    %{
      "subject_type" => type,
      "subject_id" => id,
      "reason" => "fabricated_evidence",
      "description" => "The submitted evidence appears fabricated and needs independent review."
    }
  end

  defp resolve_case!(case_record, moderator, disposition, reason) do
    {:ok, assigned} = Moderation.assign(Scope.for_account(moderator), case_record)

    {:ok, decided} =
      Moderation.resolve(Scope.for_account(moderator), assigned, disposition, reason)

    decided
  end

  defp valid_resolution do
    "The evidence was independently reviewed and supports this moderation outcome."
  end

  defp moderator_fixture do
    account_fixture()
    |> set_authorization(%{
      state: "active",
      platform_role: "moderator",
      trust_tier: "reviewer"
    })
  end

  defp admin_fixture do
    account_fixture()
    |> set_authorization(%{state: "active", platform_role: "admin", trust_tier: "reviewer"})
  end

  defp set_authorization(account, attrs) do
    account
    |> Account.authorization_changeset(attrs)
    |> Repo.update!()
  end

  defp repository_fixture do
    unique = System.unique_integer([:positive])

    Repo.insert!(%Repository{
      host: "github.com",
      owner: "moderation-owner-#{unique}",
      name: "repository-#{unique}",
      canonical_url: "https://github.com/moderation-owner-#{unique}/repository-#{unique}",
      participation_mode: "community",
      listing_status: "listed"
    })
  end

  defp restricted_scan_fixture(repository, submitter) do
    Repo.insert!(%Scan{
      repository_id: repository.id,
      submitted_by_id: submitter.id,
      commit_sha: String.duplicate("a", 40),
      commit_committed_at: DateTime.utc_now(),
      provenance: "human",
      review_kind: "code_review",
      review_status: "quarantined",
      visibility: "restricted"
    })
  end
end
