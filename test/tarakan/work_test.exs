defmodule Tarakan.WorkTest do
  use Tarakan.DataCase, async: true

  import Tarakan.ScansFixtures

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{ApiCredentials, Scope}
  alias Tarakan.Work
  alias Tarakan.Work.{Contribution, ReviewTask}

  setup do
    creator = github_account_fixture()
    repository = listed_github_repository_fixture(creator)
    %{creator: creator, repository: repository}
  end

  test "new task proposals are public immediately", %{creator: creator, repository: repository} do
    assert {:ok, task} = Work.create_task(repository, creator, valid_review_task_attributes())

    assert task.status == "proposed"
    assert task.visibility == "public"
    assert task.published_at == nil
    assert task.kind == "threat_model"
    assert task.commit_committed_at == ~U[2026-07-01 12:00:00.000000Z]
    assert [listed] = Work.list_tasks(repository)
    assert listed.id == task.id
    assert Work.get_visible_task(task.id).id == task.id
  end

  test "probation accounts can propose at most three tasks per day", %{
    creator: creator,
    repository: repository
  } do
    for number <- 1..3 do
      attrs = valid_review_task_attributes(%{"title" => "Bounded proposal #{number}"})
      assert {:ok, _task} = Work.create_task(repository, creator, attrs)
    end

    assert {:error, :proposal_limit} =
             Work.create_task(
               repository,
               creator,
               valid_review_task_attributes(%{"title" => "One proposal too many"})
             )
  end

  test "a scoped credential cannot use account ownership to bypass task read scope", %{
    creator: creator,
    repository: repository
  } do
    task = proposed_review_task_fixture(repository, creator)

    # Restrict the task so only privileged/tasks:read owners can see it.
    assert {:ok, restricted} =
             Work.quarantine_task(
               task,
               Scope.for_account(moderator_account_fixture()),
               "Deliberately restricted to exercise the credential scope boundary."
             )

    assert restricted.visibility == "restricted"

    findings_only =
      Scope.for_account(creator,
        token_scopes: ["findings:submit"],
        authentication_method: :api_credential
      )

    assert Work.list_tasks(repository, scope: findings_only) == []
    assert Work.get_visible_task(task.id, findings_only) == nil

    task_reader =
      Scope.for_account(creator,
        token_scopes: ["tasks:read"],
        authentication_method: :api_credential
      )

    assert [%{id: task_id}] = Work.list_tasks(repository, scope: task_reader)
    assert task_id == task.id
    assert Work.get_visible_task(task.id, task_reader).id == task.id
  end

  test "stewards and moderators can publish a proposal, including their own", %{
    creator: creator,
    repository: repository
  } do
    task = proposed_review_task_fixture(repository, creator)
    outsider = account_fixture()

    assert {:error, :unauthorized} =
             Work.publish_task(task, outsider, %{"reason" => "This appears safely scoped."})

    # Creator who is also a moderator/steward may publish their own proposal
    # (repo owners need this for hosted projects and solo workflows).
    creator = moderator_account_fixture() |> copy_identity_to_task_creator(task)

    assert {:ok, open} =
             Work.publish_task(task, creator, %{
               "reason" => "As repository steward I am opening this job for agents."
             })

    assert open.status == "open"
    assert open.published_at
    assert [%{action: "publish", account_id: creator_id}] = open.decisions
    assert creator_id == creator.id
    assert [public] = Work.list_tasks(repository)
    assert public.id == open.id
  end

  test "an independent moderator can still publish someone else's proposal", %{
    creator: creator,
    repository: repository
  } do
    task = proposed_review_task_fixture(repository, creator)
    moderator = moderator_account_fixture()

    assert {:ok, open} =
             Work.publish_task(task, moderator, %{
               "reason" => "The scope is bounded, safe, and useful to contributors."
             })

    assert open.status == "open"
    assert open.disclosed_by_id == moderator.id
  end

  test "publishing independently approved work lists a pending repository", %{
    creator: creator,
    repository: repository
  } do
    repository =
      repository
      |> Tarakan.Repositories.Repository.listing_changeset(%{listing_status: "pending"})
      |> Repo.update!()

    task = proposed_review_task_fixture(repository, creator)
    moderator = moderator_account_fixture()
    Tarakan.Repositories.subscribe()
    Tarakan.Activity.subscribe()

    assert {:ok, open} =
             Work.publish_task(task, moderator, %{
               "reason" => "The bounded task is independently approved for the public queue."
             })

    assert open.repository.listing_status == "listed"
    assert Repo.get!(Tarakan.Repositories.Repository, repository.id).listing_status == "listed"
    assert_received {:repository_registered, %{id: repository_id, listing_status: "listed"}}
    assert repository_id == repository.id
    assert_received {:activity, %{kind: :registration, owner: "openai", name: "codex"}}
    assert [public] = Work.list_tasks(open.repository)
    assert public.id == open.id
  end

  test "task publication never lifts repository quarantine", %{
    creator: creator,
    repository: repository
  } do
    repository =
      repository
      |> Tarakan.Repositories.Repository.listing_changeset(%{listing_status: "quarantined"})
      |> Repo.update!()

    task = proposed_review_task_fixture(repository, creator)

    assert {:ok, open} =
             Work.publish_task(task, moderator_account_fixture(), %{
               "reason" => "This decision must not override a separate repository quarantine."
             })

    assert open.repository.listing_status == "quarantined"
    assert Work.list_tasks(open.repository) == []
  end

  test "the creator can claim and perform their own published job", %{
    creator: creator,
    repository: repository
  } do
    task = review_task_fixture(repository, creator)
    assert {:ok, claimed} = Work.claim_task(task, creator)
    assert claimed.claimed_by_id == creator.id
    assert claimed.status == "claimed"

    assert {:ok, submitted} =
             Work.submit_task(claimed, creator, valid_contribution_attributes())

    assert submitted.status == "submitted"
    assert submitted.contribution.account_id == creator.id
  end

  test "a credential without the claim grant cannot release its account's claim", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    task = review_task_fixture(repository, creator)
    assert {:ok, claimed} = Work.claim_task(task, worker)

    read_only_scope =
      Scope.for_account(worker,
        token_scopes: ["tasks:read"],
        authentication_method: :api_credential
      )

    assert {:error, :unauthorized} = Work.release_task(claimed, read_only_scope)

    assert {:ok, _token, credential} =
             ApiCredentials.create(worker, %{
               name: "claim worker",
               scopes: ["tasks:claim"]
             })

    claim_scope =
      Accounts.scope_for_account(worker,
        token_id: credential.id,
        token_scopes: credential.scopes,
        authentication_method: :api_credential
      )

    assert {:ok, released} = Work.release_task(claimed, claim_scope)
    assert released.status == "open"
  end

  test "only the active claimant can renew a lease", %{creator: creator, repository: repository} do
    worker = account_fixture()
    outsider = account_fixture()
    task = review_task_fixture(repository, creator)
    assert {:ok, claimed} = Work.claim_task(task, worker)

    shortened =
      claimed
      |> Ecto.Changeset.change(claim_expires_at: DateTime.add(DateTime.utc_now(), 60, :second))
      |> Repo.update!()

    assert {:error, :not_claimant} = Work.renew_claim(shortened, outsider)
    assert {:ok, renewed} = Work.renew_claim(shortened, worker)
    assert DateTime.diff(renewed.claim_expires_at, shortened.claim_expires_at, :second) > 60
  end

  test "a credential revoked after scope creation cannot commit a transition", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    task = review_task_fixture(repository, creator)

    assert {:ok, _token, credential} =
             ApiCredentials.create(worker, %{
               name: "short lived worker",
               scopes: ["tasks:claim"]
             })

    stale_scope =
      Accounts.scope_for_account(worker,
        token_id: credential.id,
        token_scopes: credential.scopes,
        authentication_method: :api_credential
      )

    assert {:ok, _revoked} = ApiCredentials.revoke(worker, credential.id)
    assert {:error, :unauthorized} = Work.claim_task(task, stale_scope)
    assert Work.get_task(task.id).status == "open"
  end

  test "work stays public through submission, acceptance, and disclosure", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    reviewer = reviewer_account_fixture()
    task = review_task_fixture(repository, creator)

    assert {:ok, claimed} = Work.claim_task(task, worker)
    assert claimed.status == "claimed"
    assert ReviewTask.claim_active?(claimed)

    assert {:ok, submitted} =
             Work.submit_task(claimed, worker, valid_contribution_attributes())

    assert submitted.status == "submitted"
    assert submitted.visibility == "public"
    assert submitted.completed_at == nil
    assert submitted.submitted_at
    assert %Contribution{version: 1, account_id: worker_id} = submitted.contribution
    assert worker_id == worker.id

    assert [%{id: listed_id}] = Work.list_tasks(repository)
    assert listed_id == submitted.id
    anonymous_view = Work.get_visible_task(submitted.id)
    assert anonymous_view.contribution.summary =~ "boundary"
    assert anonymous_view.contribution.evidence =~ "negative authorization"
    assert anonymous_view.decisions == []

    assert {:error, :not_independent} =
             Work.accept_task(submitted, reviewer_account(creator), valid_decision_attributes())

    assert {:error, :not_independent} =
             Work.accept_task(submitted, reviewer_account(worker), valid_decision_attributes())

    assert {:ok, accepted} =
             Work.accept_task(submitted, reviewer, valid_decision_attributes())

    assert accepted.status == "accepted"
    assert accepted.visibility == "public"
    assert accepted.completed_at
    assert accepted.reviewed_by_id == reviewer.id
    assert Work.get_visible_task(accepted.id).id == accepted.id

    assert {:error, :unauthorized} =
             Work.disclose_task(accepted, account_fixture(), "public_summary", %{
               "reason" => "An ordinary account must not control public disclosure."
             })

    discloser = moderator_account_fixture()

    assert {:ok, disclosed} =
             Work.disclose_task(accepted, discloser, "public_summary", %{
               "reason" =>
                 "The raw evidence needs redaction; the summary alone stays on the record."
             })

    assert disclosed.visibility == "public_summary"
    assert disclosed.disclosed_by_id == discloser.id
    assert disclosed.disclosed_at
    assert [public] = Work.list_tasks(repository)
    assert public.contribution.summary =~ "boundary"
    assert public.contribution.evidence == nil
    assert Enum.map(public.contributions, & &1.id) == [public.contribution.id]
    assert public.decisions == []

    worker_view = Work.get_visible_task(accepted.id, Scope.for_account(worker))
    assert worker_view.contribution.evidence =~ "negative authorization"
  end

  test "full disclosure needs no verification gates", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    reviewer = reviewer_account_fixture()
    discloser = moderator_account_fixture()
    task = review_task_fixture(repository, creator)
    {:ok, task} = Work.claim_task(task, worker)
    {:ok, task} = Work.submit_task(task, worker, valid_contribution_attributes())
    {:ok, accepted} = Work.accept_task(task, reviewer, valid_decision_attributes())

    attrs = %{
      "reason" => "The complete evidence is safe and materially useful to maintainers."
    }

    assert {:ok, disclosed} = Work.disclose_task(accepted, discloser, "public", attrs)
    assert disclosed.repository.id == repository.id
    assert disclosed.visibility == "public"
    assert disclosed.sensitive_data_reviewed_at
    assert disclosed.sensitive_data_reviewed_by_id == discloser.id

    public = Work.get_visible_task(disclosed.id)
    assert public.contribution.evidence =~ "negative authorization"
    assert public.decisions == []
  end

  test "requested changes produce immutable contribution versions", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    reviewer = reviewer_account_fixture()
    task = review_task_fixture(repository, creator)
    {:ok, task} = Work.claim_task(task, worker)
    {:ok, submitted} = Work.submit_task(task, worker, valid_contribution_attributes())

    assert {:ok, changes_requested} =
             Work.request_changes(submitted, reviewer, %{
               "reason" => "The evidence does not cover the second authorization entry point.",
               "evidence" => "Independent tracing found an untested path in lib/webhook.ex."
             })

    assert changes_requested.status == "changes_requested"
    assert [%{id: listed_id}] = Work.list_tasks(repository)
    assert listed_id == changes_requested.id

    {:ok, reclaimed} = Work.claim_task(changes_requested, worker)

    public_reclaimed = Work.get_visible_task(reclaimed.id)
    assert public_reclaimed.status == "claimed"
    assert public_reclaimed.contribution.version == 1
    assert public_reclaimed.decisions == []

    worker_view = Work.get_visible_task(reclaimed.id, Scope.for_account(worker))
    assert worker_view.contribution.version == 1
    assert worker_view.decisions != []

    assert {:ok, resubmitted} =
             Work.submit_task(reclaimed, worker, %{
               "provenance" => "human",
               "summary" => "Both authorization entry points are now covered.",
               "evidence" =>
                 "Added and ran negative authorization tests for controller and webhook paths."
             })

    assert resubmitted.contribution.version == 2
    assert Enum.map(resubmitted.contributions, & &1.version) |> Enum.sort() == [1, 2]

    assert Enum.at(Enum.sort_by(resubmitted.contributions, & &1.version), 0).summary =~
             "organization boundary"
  end

  test "submission requires reproducible evidence and matching provenance", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    task = review_task_fixture(repository, creator, %{"capability" => "human"})
    {:ok, task} = Work.claim_task(task, worker)

    assert {:error, changeset} =
             Work.submit_task(task, worker, %{
               "provenance" => "human",
               "summary" => "Reviewed",
               "evidence" => ""
             })

    assert "can't be blank" in errors_on(changeset).evidence

    assert {:error, :capability_mismatch} =
             Work.submit_task(task, worker, %{
               "provenance" => "agent",
               "summary" => "An unattended agent produced this result.",
               "evidence" => "Agent output was captured without any manual reproduction."
             })

    assert Work.get_task!(task.id).status == "claimed"
  end

  test "probation accounts have one active claim and active accounts have three", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    first = review_task_fixture(repository, creator)
    second = review_task_fixture(repository, creator)

    assert {:ok, _first} = Work.claim_task(first, worker)
    assert {:error, :claim_limit} = Work.claim_task(second, worker)

    active_worker =
      worker
      |> Tarakan.Accounts.Account.authorization_changeset(%{state: "active"})
      |> Repo.update!()

    assert {:ok, _second} = Work.claim_task(second, active_worker)
  end

  test "submitted unresolved work still consumes a claimant slot", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    first = review_task_fixture(repository, creator)
    second = review_task_fixture(repository, creator)

    {:ok, first} = Work.claim_task(first, worker)
    assert {:ok, submitted} = Work.submit_task(first, worker, valid_contribution_attributes())
    assert submitted.status == "submitted"
    assert {:error, :claim_limit} = Work.claim_task(second, worker)
  end

  test "repeating an active claim emits no duplicate audit or broadcast", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    task = review_task_fixture(repository, creator)
    Work.subscribe(repository.id)

    assert {:ok, claimed} = Work.claim_task(task, worker)
    task_id = task.id
    assert_received {:review_task_updated, ^task_id}

    audit_count =
      Tarakan.Audit.Event
      |> where(
        [event],
        event.subject_type == "Tarakan.Work.ReviewTask" and event.subject_id == ^task_id
      )
      |> Repo.aggregate(:count)

    assert {:ok, repeated} = Work.claim_task(claimed, worker)
    assert repeated.claim_expires_at == claimed.claim_expires_at
    refute_receive {:review_task_updated, ^task_id}

    assert audit_count ==
             Tarakan.Audit.Event
             |> where(
               [event],
               event.subject_type == "Tarakan.Work.ReviewTask" and event.subject_id == ^task_id
             )
             |> Repo.aggregate(:count)
  end

  test "claim and release churn shares an account-global mutation limit", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    task = review_task_fixture(repository, creator)

    assert {:ok, claimed} = Work.claim_task(task, worker)
    assert {:ok, open} = Work.release_task(claimed, worker)

    for _attempt <- 1..28 do
      assert {:error, :not_claimant} = Work.release_task(open, worker)
    end

    assert {:error, :claim_rate_limited} = Work.release_task(open, worker)
  end

  test "an expired lease can be reclaimed", %{creator: creator, repository: repository} do
    worker = account_fixture()
    replacement = account_fixture()
    task = review_task_fixture(repository, creator)
    {:ok, task} = Work.claim_task(task, worker)

    task
    |> Ecto.Changeset.change(claim_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()

    assert {:ok, reclaimed} = Work.claim_task(task, replacement)
    assert reclaimed.claimed_by_id == replacement.id
    assert ReviewTask.claim_active?(reclaimed)
  end

  test "authorization is rechecked against locked database state", %{
    creator: creator,
    repository: repository
  } do
    task = review_task_fixture(repository, creator)

    repository
    |> Tarakan.Repositories.Repository.participation_changeset(%{participation_mode: "paused"})
    |> Repo.update!()

    # `task.repository` is deliberately stale and still says the repository is
    # open. The locked row is reloaded before Policy runs again.
    assert task.repository.participation_mode != "paused"
    assert {:error, :unauthorized} = Work.claim_task(task, account_fixture())
    assert Work.get_task!(task.id).status == "open"
  end

  test "review decisions require meaningful independent evidence", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    reviewer = reviewer_account_fixture()
    task = review_task_fixture(repository, creator)
    {:ok, task} = Work.claim_task(task, worker)
    {:ok, task} = Work.submit_task(task, worker, valid_contribution_attributes())

    assert {:error, changeset} =
             Work.reject_task(task, reviewer, %{
               "reason" => "Not reproduced",
               "evidence" => ""
             })

    assert "can't be blank" in errors_on(changeset).evidence
    assert Work.get_task!(task.id).status == "submitted"
  end

  test "creators may cancel idle work but not active or submitted work", %{
    creator: creator,
    repository: repository
  } do
    task = proposed_review_task_fixture(repository, creator)

    assert {:ok, cancelled} =
             Work.cancel_task(task, creator, %{
               "reason" => "The requested scope was superseded by a more precise proposal."
             })

    assert cancelled.status == "cancelled"
    assert cancelled.visibility == "public"
    assert Work.get_visible_task(cancelled.id).status == "cancelled"

    task = review_task_fixture(repository, creator)
    {:ok, claimed} = Work.claim_task(task, account_fixture())

    assert {:error, :active_work} =
             Work.cancel_task(claimed, creator, %{
               "reason" => "I should not disrupt work that is already in progress."
             })
  end

  test "broadcasts identifiers without leaking restricted task contents", %{
    creator: creator,
    repository: repository
  } do
    Work.subscribe(repository.id)

    {:ok, task} = Work.create_task(repository, creator, valid_review_task_attributes())
    task_id = task.id
    assert_received {:review_task_created, ^task_id}

    moderator = moderator_account_fixture()

    {:ok, _task} =
      Work.publish_task(task, moderator, %{
        "reason" => "The proposal is safe and bounded for community review."
      })

    assert_received {:review_task_published, ^task_id}

    actions =
      Tarakan.Audit.Event
      |> where(
        [event],
        event.subject_type == "Tarakan.Work.ReviewTask" and event.subject_id == ^task_id
      )
      |> order_by([event], asc: event.inserted_at, asc: event.id)
      |> Repo.all()
      |> Enum.map(& &1.action)

    assert actions == ["review_task_created", "review_task_published"]
  end

  test "finding-kind complete with document creates linked Review and findings", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()

    task =
      review_task_fixture(repository, creator, %{"kind" => "code_review", "capability" => "agent"})

    {:ok, claimed} = Work.claim_task(task, worker)

    assert {:ok, submitted} = Work.submit_task(claimed, worker, valid_document_attributes())

    assert submitted.status == "submitted"
    assert submitted.linked_review_id
    assert submitted.contribution == nil
    assert submitted.contributions == []

    review = submitted.linked_review
    assert review.id == submitted.linked_review_id
    assert review.source_request_id == submitted.id
    assert review.findings_count == 2
    assert review.review_status == "quarantined"
    assert review.review_kind == "code_review"
    assert review.provenance == "agent"
    assert review.prompt_version =~ ~r/#req#{submitted.id}v1$/
    assert Tarakan.Reputation.review_stake(review) == %{amount: 10, status: :at_risk}
    review_id = review.id

    assert Repo.exists?(
             from(event in Tarakan.Audit.Event,
               where:
                 event.action == "review_submitted" and
                   event.subject_type == "Tarakan.Scans.Scan" and event.subject_id == ^review_id
             )
           )

    repository = Tarakan.Repositories.get_github_repository(repository.owner, repository.name)
    assert repository.scan_count >= 1
    assert repository.open_findings_count == 2
    assert repository.status == "findings"

    scans = Tarakan.Scans.list_scans(repository)
    assert Enum.any?(scans, &(&1.id == review.id))
  end

  test "document path resubmit after changes_requested uses attempt suffix v2", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    reviewer = reviewer_account_fixture()

    task =
      review_task_fixture(repository, creator, %{"kind" => "code_review", "capability" => "agent"})

    {:ok, claimed} = Work.claim_task(task, worker)

    {:ok, first} =
      Work.submit_task(
        claimed,
        worker,
        valid_document_attributes(%{"prompt_version" => "client-pv"})
      )

    assert first.linked_review.prompt_version == "client-pv#req#{first.id}v1"
    first_review_id = first.linked_review_id

    {:ok, changes} =
      Work.request_changes(first, reviewer, %{
        "reason" => "Need a second pass with tighter evidence on the OAuth path.",
        "evidence" => "Independent tracing found an untested path in lib/oauth.ex."
      })

    {:ok, claimed2} = Work.claim_task(changes, worker)

    {:ok, second} =
      Work.submit_task(
        claimed2,
        worker,
        valid_document_attributes(%{"prompt_version" => "client-pv"})
      )

    assert second.linked_review_id != first_review_id
    assert second.linked_review.prompt_version == "client-pv#req#{second.id}v2"
    assert second.linked_review.source_request_id == second.id
    assert Tarakan.Scans.count_reviews_for_request(second.id) == 2
  end

  test "long client prompt_version is truncated so attempt suffix always fits", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()

    task =
      review_task_fixture(repository, creator, %{"kind" => "code_review", "capability" => "agent"})

    {:ok, claimed} = Work.claim_task(task, worker)
    long = String.duplicate("p", 100)

    assert {:ok, submitted} =
             Work.submit_task(
               claimed,
               worker,
               valid_document_attributes(%{"prompt_version" => long})
             )

    pv = submitted.linked_review.prompt_version
    assert String.length(pv) <= 100
    assert String.ends_with?(pv, "#req#{submitted.id}v1")
  end

  test "write_fix rejects document and accepts prose", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()

    task =
      review_task_fixture(repository, creator, %{"kind" => "write_fix", "capability" => "human"})

    {:ok, claimed} = Work.claim_task(task, worker)

    assert {:error, :document_not_allowed} =
             Work.submit_task(claimed, worker, valid_document_attributes())

    assert {:ok, submitted} = Work.submit_task(claimed, worker, valid_contribution_attributes())
    assert submitted.linked_review_id == nil
    assert submitted.contribution
  end

  test "legacy prose complete still works without document in dual mode", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    task = review_task_fixture(repository, creator, %{"kind" => "code_review"})
    {:ok, claimed} = Work.claim_task(task, worker)

    assert {:ok, submitted} = Work.submit_task(claimed, worker, valid_contribution_attributes())
    assert submitted.linked_review_id == nil
    assert submitted.contribution.version == 1
  end

  test "accept with linked_review succeeds; restricted linked review blocks accept", %{
    creator: creator,
    repository: repository
  } do
    worker = account_fixture()
    reviewer = reviewer_account_fixture()

    task =
      review_task_fixture(repository, creator, %{"kind" => "code_review", "capability" => "agent"})

    {:ok, claimed} = Work.claim_task(task, worker)
    {:ok, submitted} = Work.submit_task(claimed, worker, valid_document_attributes())

    assert {:ok, accepted} = Work.accept_task(submitted, reviewer, valid_decision_attributes())
    assert accepted.status == "accepted"

    task2 =
      review_task_fixture(repository, creator, %{
        "kind" => "threat_model",
        "capability" => "agent"
      })

    {:ok, claimed2} = Work.claim_task(task2, worker)
    {:ok, submitted2} = Work.submit_task(claimed2, worker, valid_document_attributes())

    submitted2.linked_review
    |> Ecto.Changeset.change(visibility: "restricted")
    |> Tarakan.Repo.update!()

    assert {:error, :linked_review_restricted} =
             Work.accept_task(submitted2, reviewer, valid_decision_attributes())
  end

  defp valid_contribution_attributes do
    %{
      "provenance" => "human",
      "summary" => "The organization boundary is enforced at both entry points.",
      "evidence" =>
        "Reproduced negative authorization cases with mix test test/auth_boundary_test.exs."
    }
  end

  defp valid_document_attributes(overrides \\ %{}) do
    document =
      Jason.decode!(findings_json_fixture(2))

    Enum.into(overrides, %{
      "provenance" => "agent",
      "model" => "grok-test",
      "prompt_version" => "review-v1",
      "summary" => "Structured findings from the agent review.",
      "document" => document
    })
  end

  test "verify_findings complete records a verdict on the target Review", %{
    creator: creator,
    repository: repository
  } do
    submitter = account_fixture()
    verifier = reviewer_account_fixture()

    # Independent agent-capable submitter creates Review via Request complete
    producer_task =
      review_task_fixture(repository, creator, %{
        "kind" => "code_review",
        "capability" => "agent"
      })

    {:ok, claimed} = Work.claim_task(producer_task, submitter)
    {:ok, produced} = Work.submit_task(claimed, submitter, valid_document_attributes())
    review_id = produced.linked_review_id
    assert review_id

    # Second account cannot be the review submitter
    verify_task =
      review_task_fixture(repository, creator, %{
        "kind" => "verify_findings",
        "capability" => "hybrid",
        "title" => "Verify the structured review",
        "description" => "Independently reproduce or dispute the findings.",
        "target_review_id" => review_id
      })

    assert verify_task.target_review_id == review_id

    {:ok, vclaimed} = Work.claim_task(verify_task, verifier)

    assert {:ok, vsubmitted} =
             Work.submit_task(vclaimed, verifier, %{
               "provenance" => "hybrid",
               "verdict" => "confirmed",
               "notes" =>
                 "Independently traced each finding against the pinned commit and reproduced the reported surfaces.",
               "evidence" => "Checked app_controller create/2 and sanitizer dangerous_url?/1."
             })

    assert vsubmitted.status == "submitted"
    assert vsubmitted.linked_review_id == review_id

    {:ok, scan} = Tarakan.Scans.get_scan(Scope.for_account(verifier), review_id)
    assert length(scan.confirmations) >= 1

    assert Enum.any?(
             scan.confirmations,
             &(&1.verdict == "confirmed" and &1.account_id == verifier.id)
           )
  end

  test "verify_findings without verdict returns clear error when target is set", %{
    creator: creator,
    repository: repository
  } do
    submitter = account_fixture()
    verifier = account_fixture()

    producer =
      review_task_fixture(repository, creator, %{"kind" => "code_review", "capability" => "agent"})

    {:ok, claimed} = Work.claim_task(producer, submitter)
    {:ok, produced} = Work.submit_task(claimed, submitter, valid_document_attributes())

    verify =
      review_task_fixture(repository, creator, %{
        "kind" => "verify_findings",
        "capability" => "human",
        "target_review_id" => produced.linked_review_id
      })

    {:ok, vclaimed} = Work.claim_task(verify, verifier)

    assert {:error, :verdict_required} =
             Work.submit_task(vclaimed, verifier, valid_contribution_attributes())
  end

  defp valid_decision_attributes do
    %{
      "reason" => "The evidence independently reproduces the claimed security behavior.",
      "evidence" =>
        "Ran the negative authorization tests from a clean checkout at the pinned SHA."
    }
  end

  # Give the actual task creator moderator attributes without changing the id.
  defp copy_identity_to_task_creator(moderator, task) do
    task.created_by
    |> Tarakan.Accounts.Account.authorization_changeset(%{
      state: moderator.state,
      platform_role: moderator.platform_role,
      trust_tier: moderator.trust_tier
    })
    |> Repo.update!()
  end
end
