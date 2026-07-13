defmodule Tarakan.Scans do
  @moduledoc """
  Contributed security reviews pinned to exact commits.

  Submissions are evidence, not verdicts. Every review is public the moment
  it is submitted; independent verification and moderation change its status
  labels but never its visibility. Restriction exists only as an explicit
  moderation takedown. Repository headlines are derived from all public
  reviews.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit
  alias Tarakan.GitHub
  alias Tarakan.FindingMemory
  alias Tarakan.Moderation.Holds
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.{Repository, RepositoryMembership}
  alias Tarakan.Scans.{Confirmation, Finding, FindingCheck, Scan, ScanFormat}

  @verification_threshold 2
  @counting_provenances ~w(human hybrid)
  @public_visibilities ~w(public_summary public)

  @doc """
  Subscribes the caller to a repository's review record.

  Messages contain server-side records and must be re-authorized before they
  are rendered. Consumers receive `{:scan_submitted, scan}` and
  `{:scan_updated, scan}`.
  """
  def subscribe(repository_id) do
    Phoenix.PubSub.subscribe(Tarakan.PubSub, topic(repository_id))
  end

  @doc "Broadcasts a committed scan-state refresh to subscribed repository views."
  def broadcast_refresh(%Scan{} = scan) do
    scan = preload_record(scan)
    broadcast(scan.repository_id, {:scan_updated, scan})
    :ok
  end

  def severities, do: ScanFormat.severities()
  def provenances, do: Scan.provenances()
  def review_kinds, do: Scan.review_kinds()
  def review_statuses, do: Scan.review_statuses()
  def visibilities, do: Scan.visibilities()
  def verification_threshold, do: @verification_threshold

  @doc "Rechecks stored verdict eligibility after repository authority changes."
  def revalidate_repository_authority(repository_id) when is_integer(repository_id) do
    result =
      Repo.transaction(fn ->
        repository =
          Repo.one!(
            from candidate in Repository,
              where: candidate.id == ^repository_id,
              lock: "FOR UPDATE"
          )

        scans =
          Repo.all(
            from scan in Scan,
              where: scan.repository_id == ^repository.id,
              order_by: [asc: scan.id],
              lock: "FOR UPDATE"
          )

        updated_scans =
          Enum.map(scans, fn scan ->
            case retally_scan(Repo, scan) do
              {:ok, updated_scan} -> updated_scan
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        FindingMemory.refresh_repository_checks(repository.id)

        updated_repository =
          case recalculate_repository(Repo, repository.id) do
            {:ok, updated_repository} -> updated_repository
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {updated_scans, updated_repository}
      end)

    case result do
      {:ok, {updated_scans, updated_repository}} ->
        Enum.each(updated_scans, &broadcast_refresh/1)
        Repositories.broadcast_record_updated(updated_repository)
        {:ok, updated_repository}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate_repository_authority(_repository_id), do: {:error, :not_found}

  @doc "Rechecks every repository where an account has supplied a verdict."
  def revalidate_account_authority(account_id) when is_integer(account_id) do
    report_repository_ids =
      Repo.all(
        from confirmation in Confirmation,
          join: scan in Scan,
          on: scan.id == confirmation.scan_id,
          where: confirmation.account_id == ^account_id,
          distinct: true,
          select: scan.repository_id
      )

    finding_repository_ids =
      Repo.all(
        from check in FindingCheck,
          join: canonical in assoc(check, :canonical_finding),
          where: check.account_id == ^account_id,
          distinct: true,
          select: canonical.repository_id
      )

    repository_ids = Enum.uniq(report_repository_ids ++ finding_repository_ids)

    Enum.reduce_while(repository_ids, :ok, fn repository_id, :ok ->
      case revalidate_repository_authority(repository_id) do
        {:ok, _repository} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def revalidate_account_authority(_account_id), do: {:error, :not_found}

  @doc """
  Counts distinct accounts with a public review or a verdict on one, across
  listed repositories. The public size of the auditing collective.
  """
  def public_contributor_count do
    scan_authors =
      from scan in Scan,
        join: repository in assoc(scan, :repository),
        where:
          repository.listing_status == "listed" and
            scan.visibility in @public_visibilities,
        select: %{account_id: scan.submitted_by_id}

    verifiers =
      from confirmation in Confirmation,
        join: scan in assoc(confirmation, :scan),
        join: repository in assoc(scan, :repository),
        where:
          repository.listing_status == "listed" and
            scan.visibility in @public_visibilities,
        select: %{account_id: confirmation.account_id}

    Repo.one(
      from contributor in subquery(union(scan_authors, ^verifiers)),
        select: count(contributor.account_id, :distinct)
    )
  end

  @doc """
  Lists only reviews the caller may see.

  Reviews are public from submission; a review disappears from anonymous
  callers only when moderation restricts it or quarantines its repository.
  Public summaries never include finding bodies, contributor verdict
  evidence, or private notes.
  """
  def list_scans(%Repository{} = repository), do: list_scans(nil, repository)

  def list_scans(scope, %Repository{id: repository_id}) do
    Scan
    |> where([scan], scan.repository_id == ^repository_id)
    |> order_by([scan], desc: scan.inserted_at, desc: scan.id)
    |> Repo.all()
    |> preload_record()
    |> Enum.flat_map(&expose_scan(scope, &1))
  end

  @doc """
  Fetches a review through the same disclosure rules as `list_scans/2`.
  """
  def get_scan(scope, id) do
    case Repo.get(Scan, id) do
      nil ->
        {:error, :not_found}

      scan ->
        scan = preload_record(scan)

        case expose_scan(scope, scan) do
          [visible_scan] -> {:ok, visible_scan}
          [] -> {:error, :not_found}
        end
    end
  end

  @doc "Returns a finding by its non-enumerable public ID through its parent scan's disclosure policy."
  def get_finding(scope, public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id),
         %Finding{} = stored_finding <- Repo.get_by(Finding, public_id: public_id),
         {:ok, visible_scan} <- get_scan(scope, stored_finding.scan_id),
         true <- visible_scan.details_visible,
         %Finding{} = visible_finding <-
           Enum.find(visible_scan.findings, &(&1.id == stored_finding.id)) do
      {:ok, {visible_scan, visible_finding}}
    else
      _not_visible -> {:error, :not_found}
    end
  end

  @doc """
  Lists findings whose full details are publicly disclosed, for search-engine
  discovery. Mirrors the anonymous branch of the disclosure policy: a listed
  repository and full `public` visibility - `public_summary` reviews redact
  finding bodies and are never included.
  """
  def list_indexable_findings do
    Finding
    |> join(:inner, [finding], scan in assoc(finding, :scan))
    |> join(:inner, [finding, scan], repository in assoc(scan, :repository))
    |> where(
      [finding, scan, repository],
      repository.listing_status == "listed" and scan.visibility == "public"
    )
    |> order_by([finding], asc: finding.id)
    |> select([finding], %{public_id: finding.public_id, updated_at: finding.updated_at})
    |> Repo.all()
  end

  @doc """
  Records a review submitted by the account represented by `scope`.

  The commit SHA is verified against GitHub before persistence. The review is
  public immediately; its `quarantined` status is a label meaning "awaiting
  independent verification and moderation", not a visibility gate. Only a
  moderation takedown restricts content after the fact.
  """
  def submit_scan(%Scope{} = scope, %Repository{} = repository, attrs) do
    with %Repository{} = canonical_repository <- Repo.get(Repository, repository.id),
         :ok <- Policy.authorize(scope, :submit_review, canonical_repository),
         :ok <- scan_submission_preflight(scope, canonical_repository),
         :ok <- scan_submission_quota_precheck(scope.account),
         %Account{} = submitter <- scope.account do
      do_submit_scan(scope, canonical_repository, submitter, attrs)
    else
      nil -> {:error, :unauthorized}
      {:error, :unauthorized} = error -> error
      {:error, _reason} = error -> error
    end
  end

  # Compatibility for internal callers while interfaces migrate to Scope.
  def submit_scan(%Repository{} = repository, %Account{} = submitter, attrs) do
    submit_scan(Scope.for_account(submitter), repository, attrs)
  end

  @doc """
  Rate limit + daily quota shared by ad-hoc Reviews and Request-sourced Reviews.
  Call before opening the outer transaction (and re-check daily quota under lock).
  """
  def enforce_submission_budget(%Scope{} = scope, %Repository{} = repository) do
    with :ok <- scan_submission_preflight(scope, repository),
         :ok <- scan_submission_quota_precheck(scope.account) do
      :ok
    end
  end

  @doc "Daily quota recheck under an account row lock (same limits as ad-hoc submit)."
  def enforce_submission_budget_under_lock(repo, %Account{} = account) do
    scan_submission_quota(repo, account)
  end

  @doc """
  Inserts a Review (+ findings) with no PubSub/Activity side effects.

  Callers that already hold a repository lock use this inside their outer
  transaction. Does not recalculate repository aggregates - call
  `recalculate_repository_metrics/1` after insert when needed.
  """
  def stage_review_insert(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    repository_id = required_int(attrs, "repository_id")
    submitted_by_id = required_int(attrs, "submitted_by_id")

    changeset =
      %Scan{}
      |> Scan.submission_changeset(attrs)
      |> Ecto.Changeset.put_change(:repository_id, repository_id)
      |> Ecto.Changeset.put_change(:submitted_by_id, submitted_by_id)
      |> Ecto.Changeset.put_change(:review_status, "quarantined")
      |> Ecto.Changeset.put_change(:visibility, Map.get(attrs, "visibility") || "public")
      |> maybe_put_optional(:source_request_id, attrs)
      |> maybe_put_optional(:commit_committed_at, attrs)

    with {:ok, changeset} <- validate_submission(changeset) do
      case Repo.insert(changeset) do
        {:ok, scan} -> {:ok, FindingMemory.assimilate_scan(scan)}
        {:error, %Ecto.Changeset{} = failed} -> {:error, %{failed | action: :insert}}
      end
    end
  end

  @doc "Count Reviews produced from a Request (for attempt-scoped prompt_version)."
  def count_reviews_for_request(request_id) when is_integer(request_id) do
    Repo.aggregate(
      from(scan in Scan, where: scan.source_request_id == ^request_id),
      :count
    )
  end

  @doc "DB-only repository headline recalculation (no broadcast)."
  def recalculate_repository_metrics(repository_id) when is_integer(repository_id) do
    recalculate_repository(Repo, repository_id)
  end

  @doc """
  Post-commit side effects after a Review is durable. Safe to call only after
  the outer transaction that inserted the scan has committed.
  """
  def broadcast_review_submitted(%Scan{} = scan) do
    scan = preload_record(scan)
    repository = scan.repository || Repo.get!(Repository, scan.repository_id)

    broadcast(scan.repository_id, {:scan_submitted, scan})
    Repositories.broadcast_record_updated(repository)

    if Scan.publicly_listed?(scan) and repository.listing_status == "listed" do
      Tarakan.Activity.broadcast_scan(scan, repository, scan.submitted_by)
    end

    :ok
  end

  @doc "Verifies a commit SHA against GitHub for the repository (IO; call outside locks)."
  def verify_commit_sha(%Repository{} = repository, sha) when is_binary(sha) do
    changeset = Ecto.Changeset.change(%Scan{}, commit_sha: String.downcase(String.trim(sha)))
    verify_commit(repository, changeset)
  end

  @doc """
  Insert a confirmation and retally under the caller's transaction.

  Caller must already hold the repository row lock. Does **not** broadcast -
  call `broadcast_verdict_recorded/3` after commit.
  """
  def stage_confirmation(%Scope{} = scope, scan_id, attrs)
      when is_integer(scan_id) and is_map(attrs) do
    account = scope.account

    locked_scan =
      Repo.one(
        from candidate in Scan,
          where: candidate.id == ^scan_id,
          lock: "FOR UPDATE"
      )

    case locked_scan do
      nil ->
        {:error, :not_found}

      %Scan{} = locked_scan ->
        repository = Repo.get!(Repository, locked_scan.repository_id)
        subject = %{locked_scan | repository: repository}

        with :ok <- Policy.authorize(scope, :verify_review, subject),
             :ok <- ensure_not_submitter(locked_scan, account) do
          changeset =
            %Confirmation{scan_id: locked_scan.id, account_id: account.id}
            |> Confirmation.changeset(attrs)

          case Repo.insert(changeset) do
            {:ok, confirmation} ->
              case retally_scan(Repo, locked_scan) do
                {:ok, updated_scan} ->
                  _ =
                    Audit.event_changeset(scope, :review_verdict_recorded, locked_scan, %{
                      from_state: scan_state(locked_scan),
                      to_state: scan_state(updated_scan),
                      metadata: %{
                        verdict: confirmation.verdict,
                        provenance: confirmation.provenance,
                        source: "request_complete"
                      }
                    })
                    |> Repo.insert()

                  case recalculate_repository(Repo, updated_scan.repository_id) do
                    {:ok, _repo} -> {:ok, preload_record(updated_scan), confirmation}
                    {:error, reason} -> {:error, reason}
                  end

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, %Ecto.Changeset{} = failed} ->
              {:error, %{failed | action: :insert}}
          end
        end
    end
  end

  @doc "Post-commit broadcasts after stage_confirmation/3."
  def broadcast_verdict_recorded(
        %Scan{} = scan,
        %Confirmation{} = confirmation,
        %Account{} = account
      ) do
    scan = preload_record(scan)
    repository = scan.repository || Repo.get!(Repository, scan.repository_id)

    broadcast(scan.repository_id, {:scan_updated, scan})
    Repositories.broadcast_record_updated(repository)

    if Scan.publicly_listed?(scan) do
      Tarakan.Activity.broadcast_verdict(confirmation, scan, repository, account)
    end

    :ok
  end

  defp required_int(attrs, key) do
    case Map.get(attrs, key) do
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
    end
  end

  defp maybe_put_optional(changeset, _field, attrs) when map_size(attrs) == 0, do: changeset

  defp maybe_put_optional(changeset, field, attrs) do
    key = to_string(field)

    case Map.fetch(attrs, key) do
      {:ok, nil} -> changeset
      {:ok, value} -> Ecto.Changeset.put_change(changeset, field, value)
      :error -> changeset
    end
  end

  @doc """
  Whether `scope` can record an independent verdict on `scan`: qualified,
  not the submitter, and not already on the record. Expects `confirmations`
  to be preloaded.
  """
  def can_record_verdict?(%Scope{account: %Account{} = account} = scope, %Scan{} = scan) do
    Policy.allowed?(scope, :verify_review, scan) and scan.submitted_by_id != account.id and
      not Enum.any?(scan.confirmations, &(&1.account_id == account.id))
  end

  def can_record_verdict?(_scope, _scan), do: false

  @doc """
  Records an attributable verification verdict.

  Submitters cannot review their own work. A human or hybrid verdict includes
  reproducible evidence and counts toward quorum; agent-only votes are retained
  as provenance but never satisfy quorum. Quorum never publishes or accepts a
  review automatically.
  """
  def record_confirmation(%Scope{} = scope, %Scan{} = scan, attrs) do
    account = scope.account

    with %Account{} <- account do
      do_record_confirmation(scope, scan.id, account, attrs)
    else
      nil -> {:error, :unauthorized}
    end
  end

  # Compatibility for existing internal callers.
  def record_confirmation(%Scan{} = scan, %Account{} = account, attrs) do
    record_confirmation(Scope.for_account(account), scan, attrs)
  end

  @doc """
  Accepts a verified review. Acceptance is a status label; it does not change
  the review's visibility, which is public unless moderation restricted it.
  """
  def accept_scan(%Scope{} = scope, %Scan{} = scan, attrs) do
    moderate_scan(scope, scan, "accepted", stringify_keys(attrs))
  end

  @doc "Rejects a review. The label changes; visibility does not."
  def reject_scan(%Scope{} = scope, %Scan{} = scan, attrs) do
    moderate_scan(scope, scan, "rejected", stringify_keys(attrs))
  end

  @doc "Marks a review contested. The label changes; visibility does not."
  def contest_scan(%Scope{} = scope, %Scan{} = scan, attrs) do
    moderate_scan(scope, scan, "contested", stringify_keys(attrs))
  end

  @doc """
  Changes a review's visibility. Reviews are public by default; this is the
  moderation takedown path (`restricted`) and the summary-redaction path
  (`public_summary`).
  """
  def update_visibility(%Scope{} = scope, %Scan{} = scan, visibility, attrs) do
    attrs = attrs |> stringify_keys() |> Map.put("visibility", visibility)
    moderate_scan(scope, scan, :current, attrs)
  end

  defp do_submit_scan(scope, repository, submitter, attrs) do
    attrs = stringify_keys(attrs)

    pre_changeset =
      %Scan{}
      |> Scan.submission_changeset(attrs)
      |> Ecto.Changeset.put_change(:repository_id, repository.id)
      |> Ecto.Changeset.put_change(:submitted_by_id, submitter.id)
      |> Ecto.Changeset.put_change(:review_status, "quarantined")
      |> Ecto.Changeset.put_change(:visibility, "public")

    with {:ok, pre_changeset} <- validate_submission(pre_changeset),
         {:ok, commit} <- verify_commit(repository, pre_changeset) do
      insert_attrs =
        attrs
        |> Map.put("repository_id", repository.id)
        |> Map.put("submitted_by_id", submitter.id)
        |> Map.put("visibility", "public")
        |> Map.put("commit_committed_at", normalize_precision(commit.committed_at))

      Multi.new()
      |> Multi.run(:locked_repository, fn repo, _changes ->
        lock_repository(repo, repository.id)
      end)
      |> Multi.run(:authorization, fn repo, %{locked_repository: locked_repository} ->
        with {:ok, fresh_scope} <-
               authorize_fresh_scope(repo, scope, :submit_review, locked_repository),
             :ok <- scan_submission_quota(repo, fresh_scope.account) do
          {:ok, fresh_scope}
        end
      end)
      |> Multi.run(:scan, fn _repo, _changes ->
        stage_review_insert(insert_attrs)
      end)
      |> Multi.insert(:stake, fn %{scan: scan} ->
        Tarakan.Reputation.Stake.changeset(%Tarakan.Reputation.Stake{}, %{
          scan_id: scan.id,
          account_id: scan.submitted_by_id,
          amount: Tarakan.Reputation.default_stake()
        })
      end)
      |> Multi.insert(:audit, fn %{authorization: fresh_scope, scan: scan} ->
        Audit.event_changeset(fresh_scope, :review_submitted, scan, %{
          from_state: nil,
          to_state: scan_state(scan)
        })
      end)
      |> Multi.run(:repository, fn repo, %{scan: scan} ->
        recalculate_repository(repo, scan.repository_id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{scan: scan}} ->
          broadcast_review_submitted(scan)
          {:ok, preload_record(scan)}

        {:error, :scan, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp do_record_confirmation(scope, scan_id, account, attrs) do
    changeset =
      %Confirmation{scan_id: scan_id, account_id: account.id}
      |> Confirmation.changeset(attrs)

    Multi.new()
    |> Multi.run(:locked_repository, fn repo, _changes ->
      lock_repository_for_scan(repo, scan_id)
    end)
    |> Multi.run(:fresh_scope, fn repo, _changes ->
      lock_fresh_scope(repo, scope)
    end)
    |> Multi.run(:locked_scan, fn repo, _changes ->
      query =
        from candidate in Scan,
          where: candidate.id == ^scan_id,
          lock: "FOR UPDATE"

      case repo.one(query) do
        nil -> {:error, :not_found}
        locked_scan -> {:ok, locked_scan}
      end
    end)
    |> Multi.run(:authorization, fn _repo, changes ->
      locked_scan = %{changes.locked_scan | repository: changes.locked_repository}
      fresh_scope = changes.fresh_scope

      with :ok <- Policy.authorize(fresh_scope, :verify_review, locked_scan),
           :ok <- ensure_not_submitter(locked_scan, fresh_scope.account) do
        {:ok, fresh_scope}
      end
    end)
    |> Multi.insert(:confirmation, changeset)
    |> Multi.run(:finding_checks, fn _repo,
                                     %{locked_scan: locked_scan, confirmation: confirmation} ->
      FindingMemory.assimilate_report_check(locked_scan, confirmation, account)
      {:ok, :recorded}
    end)
    |> Multi.run(:scan, fn repo, %{locked_scan: locked_scan} ->
      retally_scan(repo, locked_scan)
    end)
    |> Multi.insert(:audit, fn %{
                                 authorization: fresh_scope,
                                 locked_scan: locked_scan,
                                 confirmation: confirmation,
                                 scan: updated_scan
                               } ->
      Audit.event_changeset(fresh_scope, :review_verdict_recorded, locked_scan, %{
        from_state: scan_state(locked_scan),
        to_state: scan_state(updated_scan),
        metadata: %{
          verdict: confirmation.verdict,
          provenance: confirmation.provenance
        }
      })
    end)
    |> Multi.run(:repository, fn repo, %{scan: updated_scan} ->
      recalculate_repository(repo, updated_scan.repository_id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok,
       %{
         authorization: fresh_scope,
         confirmation: confirmation,
         scan: updated_scan,
         repository: updated_repository
       }} ->
        updated_scan = preload_record(updated_scan)
        broadcast(updated_scan.repository_id, {:scan_updated, updated_scan})
        Repositories.broadcast_record_updated(updated_repository)

        if Scan.publicly_listed?(updated_scan) do
          Tarakan.Activity.broadcast_verdict(
            confirmation,
            updated_scan,
            updated_repository,
            fresh_scope.account
          )
        end

        {:ok, updated_scan}

      {:error, :confirmation, changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp moderate_scan(scope, scan, requested_status, attrs) do
    account = scope.account

    with %Account{} <- account,
         :ok <- verify_disclosure_identity(scan, requested_status, attrs) do
      Multi.new()
      |> Multi.run(:locked_repository, fn repo, _changes ->
        lock_repository_for_scan(repo, scan.id)
      end)
      |> Multi.run(:fresh_scope, fn repo, _changes ->
        lock_fresh_scope(repo, scope)
      end)
      |> Multi.run(:locked_scan, fn repo, _changes ->
        query =
          from candidate in Scan,
            where: candidate.id == ^scan.id,
            lock: "FOR UPDATE"

        case repo.one(query) do
          nil -> {:error, :not_found}
          locked_scan -> {:ok, locked_scan}
        end
      end)
      |> Multi.run(:authorization, fn _repo, changes ->
        locked_scan = %{changes.locked_scan | repository: changes.locked_repository}
        fresh_scope = changes.fresh_scope
        status = effective_status(requested_status, locked_scan)

        with :ok <- Policy.authorize(fresh_scope, :moderate_review, locked_scan),
             :ok <- ensure_not_submitter(locked_scan, fresh_scope.account),
             :ok <- ensure_moderation_hold_allows(fresh_scope, locked_scan),
             :ok <- ensure_transition_allowed(locked_scan, status) do
          {:ok, fresh_scope}
        end
      end)
      |> Multi.update(:scan, fn %{authorization: fresh_scope, locked_scan: locked_scan} ->
        status = effective_status(requested_status, locked_scan)
        Scan.moderation_changeset(locked_scan, status, attrs, fresh_scope.account_id)
      end)
      |> Multi.insert(:audit, fn %{
                                   authorization: fresh_scope,
                                   locked_scan: locked_scan,
                                   scan: updated_scan
                                 } ->
        Audit.event_changeset(fresh_scope, :review_moderated, locked_scan, %{
          from_state: scan_state(locked_scan),
          to_state: scan_state(updated_scan),
          reason_code: updated_scan.moderation_reason,
          metadata: %{visibility: updated_scan.visibility}
        })
      end)
      |> Multi.run(:repository, fn repo, %{scan: updated_scan} ->
        recalculate_repository(repo, updated_scan.repository_id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok,
         %{
           locked_repository: previous_repository,
           locked_scan: previous_scan,
           scan: updated_scan,
           repository: updated_repository
         }} ->
          updated_scan = preload_record(updated_scan)
          broadcast(updated_scan.repository_id, {:scan_updated, updated_scan})
          Repositories.broadcast_record_updated(updated_repository)

          if previous_repository.listing_status != "listed" and
               updated_repository.listing_status == "listed" do
            Tarakan.Activity.broadcast_registration(updated_repository)
          end

          if Scan.publicly_listed?(updated_scan) and not Scan.publicly_listed?(previous_scan) do
            Tarakan.Activity.broadcast_scan(
              updated_scan,
              updated_repository,
              updated_scan.submitted_by
            )
          end

          {:ok, updated_scan}

        {:error, :scan, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    else
      nil -> {:error, :unauthorized}
      {:error, _reason} = error -> error
    end
  end

  defp validate_submission(changeset) do
    if changeset.valid? do
      {:ok, changeset}
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp authorize_fresh_scope(repo, %Scope{} = scope, action, resource) do
    with {:ok, fresh_scope} <- lock_fresh_scope(repo, scope),
         :ok <- Policy.authorize(fresh_scope, action, resource) do
      {:ok, fresh_scope}
    end
  end

  defp lock_fresh_scope(repo, %Scope{} = scope) do
    account =
      repo.one!(
        from account in Account,
          where: account.id == ^scope.account_id,
          lock: "FOR UPDATE"
      )

    fresh_scope =
      case Accounts.refresh_scope_for_account(account, scope) do
        {:ok, fresh_scope} -> fresh_scope
        {:error, reason} -> repo.rollback(reason)
      end

    {:ok, fresh_scope}
  end

  defp lock_repository(repo, repository_id) do
    case repo.one(
           from repository in Repository,
             where: repository.id == ^repository_id,
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :not_found}
      repository -> {:ok, repository}
    end
  end

  defp lock_repository_for_scan(repo, scan_id) do
    case repo.one(from scan in Scan, where: scan.id == ^scan_id, select: scan.repository_id) do
      nil -> {:error, :not_found}
      repository_id -> lock_repository(repo, repository_id)
    end
  end

  defp scan_submission_quota(_repo, %Account{platform_role: role})
       when role in ["moderator", "admin"],
       do: :ok

  defp scan_submission_quota(repo, %Account{} = account) do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

    count =
      repo.aggregate(
        from(scan in Scan,
          where: scan.submitted_by_id == ^account.id and scan.inserted_at >= ^cutoff
        ),
        :count
      )

    limit = scan_submission_limit(account)

    if count < limit, do: :ok, else: {:error, :submission_limit}
  end

  defp scan_submission_quota_precheck(%Account{} = account) do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

    count =
      Repo.aggregate(
        from(scan in Scan,
          where: scan.submitted_by_id == ^account.id and scan.inserted_at >= ^cutoff
        ),
        :count
      )

    if count < scan_submission_limit(account), do: :ok, else: {:error, :submission_limit}
  end

  defp scan_submission_quota_precheck(_account), do: {:error, :unauthorized}

  defp scan_submission_limit(%Account{platform_role: role}) when role in ["moderator", "admin"],
    do: 10_000

  defp scan_submission_limit(%Account{trust_tier: "reviewer"}), do: 250
  defp scan_submission_limit(%Account{state: "active"}), do: 50
  defp scan_submission_limit(%Account{}), do: 5

  defp scan_submission_preflight(
         %Scope{account_id: account_id},
         %Repository{id: repository_id}
       ) do
    with :ok <- rate_check({:scan_submission_account, account_id}, 20, 60),
         :ok <- rate_check({:scan_submission, account_id, repository_id}, 10, 60) do
      :ok
    end
  end

  defp rate_check(key, limit, period) do
    case Tarakan.RateLimiter.check(key, limit, period) do
      :ok -> :ok
      {:error, _reason, _retry_after} -> {:error, :submission_rate_limited}
    end
  end

  defp normalize_precision(nil), do: nil
  defp normalize_precision(%DateTime{} = datetime), do: DateTime.add(datetime, 0, :microsecond)

  defp verify_commit(repository, changeset) do
    sha = Ecto.Changeset.get_field(changeset, :commit_sha)

    if Repository.hosted?(repository) do
      verify_hosted_commit(repository, sha)
    else
      verify_github_commit(repository, sha)
    end
  end

  defp verify_hosted_commit(%Repository{} = repository, sha) do
    dir = Tarakan.HostedRepositories.Storage.dir(repository)

    case Tarakan.Git.Local.read_commit(dir, sha) do
      {:ok, commit} -> {:ok, commit}
      :miss -> {:error, :commit_not_found}
    end
  end

  defp verify_github_commit(repository, sha) do
    with {:identity_before, {:ok, _metadata}} <-
           {:identity_before, GitHub.verify_public_identity(repository)},
         {:commit, {:ok, commit}} <-
           {:commit, GitHub.fetch_commit(repository.owner, repository.name, sha)},
         :ok <- ensure_requested_commit(commit, sha),
         {:identity_after, {:ok, _metadata}} <-
           {:identity_after, GitHub.verify_public_identity(repository)} do
      {:ok, commit}
    else
      {:commit, {:error, :not_found}} ->
        {:error, :commit_not_found}

      {step, {:error, reason}} when step in [:identity_before, :identity_after] ->
        if reason in [:not_found, :not_public],
          do: {:error, :identity_changed},
          else: {:error, reason}

      {:commit, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_requested_commit(%{sha: sha}, sha), do: :ok
  defp ensure_requested_commit(_commit, _requested_sha), do: {:error, :commit_mismatch}

  defp verify_disclosure_identity(scan, :current, attrs) when is_map(attrs) do
    visibility = Map.get(attrs, "visibility") || Map.get(attrs, :visibility)

    if visibility in @public_visibilities do
      case Repo.get(Repository, scan.repository_id) do
        %Repository{} = repository ->
          case GitHub.verify_public_identity(repository) do
            {:ok, _metadata} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        nil ->
          {:error, :not_found}
      end
    else
      :ok
    end
  end

  defp verify_disclosure_identity(_scan, _requested_status, _attrs), do: :ok

  # Tallies are recalculated from immutable verdict rows. Only human and hybrid
  # verification counts; agent-only agreement is never a quorum vote.
  defp retally_scan(repo, scan) do
    tallies =
      repo.one(
        from confirmation in Confirmation,
          join: account in Account,
          on: account.id == confirmation.account_id,
          left_join: membership in RepositoryMembership,
          on:
            membership.repository_id == ^scan.repository_id and
              membership.account_id == account.id and membership.status == "verified" and
              membership.role in ["reviewer", "steward"],
          where:
            confirmation.scan_id == ^scan.id and
              confirmation.provenance in ^@counting_provenances and
              account.state in ["probation", "active"] and
              (account.trust_tier == "reviewer" or
                 account.platform_role in ["moderator", "admin"] or not is_nil(membership.id)),
          select: %{
            confirmed: count(confirmation.id) |> filter(confirmation.verdict == "confirmed"),
            disputed: count(confirmation.id) |> filter(confirmation.verdict == "disputed")
          }
      )

    verified_at =
      if tallies.confirmed - tallies.disputed >= @verification_threshold do
        scan.verified_at || DateTime.utc_now()
      end

    changes = [
      confirmations_count: tallies.confirmed,
      disputes_count: tallies.disputed,
      verified_at: verified_at
    ]

    changeset =
      if scan.review_status == "accepted" and is_nil(verified_at) do
        scan
        |> Scan.quorum_lost_changeset()
        |> Ecto.Changeset.change(changes)
      else
        Ecto.Changeset.change(scan, changes)
      end

    repo.update(changeset)
  end

  # Public aggregates follow visibility: every non-restricted review counts
  # from the moment it is submitted. A later empty review cannot erase an
  # earlier positive report.
  defp recalculate_repository(repo, repository_id) do
    repository =
      repo.one!(
        from candidate in Repository,
          where: candidate.id == ^repository_id,
          lock: "FOR UPDATE"
      )

    public_query =
      from scan in Scan,
        where:
          scan.repository_id == ^repository_id and
            scan.visibility in ^@public_visibilities

    totals =
      repo.one(
        from scan in public_query,
          select: %{scan_count: count(scan.id), last_scanned_at: max(scan.inserted_at)}
      )

    public_canonical_ids =
      from finding in Finding,
        join: scan in Scan,
        on: scan.id == finding.scan_id,
        where:
          scan.repository_id == ^repository_id and
            scan.visibility in ^@public_visibilities and
            not is_nil(finding.canonical_finding_id),
        select: finding.canonical_finding_id,
        distinct: true

    findings_count =
      repo.aggregate(
        from(canonical in Tarakan.Scans.CanonicalFinding,
          where: canonical.id in subquery(public_canonical_ids) and canonical.status != "fixed"
        ),
        :count
      )

    verified_findings_count =
      repo.aggregate(
        from(canonical in Tarakan.Scans.CanonicalFinding,
          where: canonical.id in subquery(public_canonical_ids) and canonical.status == "verified"
        ),
        :count
      )

    status =
      cond do
        totals.scan_count == 0 -> "unscanned"
        findings_count > 0 -> "findings"
        true -> "reviewed"
      end

    listing_status =
      if repository.listing_status == "pending" and totals.scan_count > 0 do
        "listed"
      else
        repository.listing_status
      end

    repository
    |> Ecto.Changeset.change(
      scan_count: totals.scan_count,
      last_scanned_at: totals.last_scanned_at,
      open_findings_count: findings_count,
      verified_findings_count: verified_findings_count,
      status: status,
      listing_status: listing_status
    )
    |> repo.update()
  end

  # Visibility is the only content gate: review status and repository
  # listing are labels, except a moderation-quarantined repository, which
  # pulls its whole record from anonymous view.
  defp expose_scan(scope, %Scan{} = scan) do
    cond do
      restricted_access?(scope, scan) ->
        [%{scan | details_visible: true}]

      scan.repository.listing_status == "quarantined" ->
        []

      scan.visibility == "public" ->
        [public_full_scan(scan)]

      scan.visibility == "public_summary" ->
        [redact_scan(scan)]

      true ->
        []
    end
  end

  defp redact_scan(scan) do
    %{
      scan
      | details_visible: false,
        notes: nil,
        moderation_notes: nil,
        findings: [],
        confirmations: []
    }
  end

  defp public_full_scan(scan) do
    confirmations = Enum.map(scan.confirmations, &%{&1 | notes: nil})
    %{scan | details_visible: true, moderation_notes: nil, confirmations: confirmations}
  end

  defp restricted_access?(nil, _scan), do: false

  defp restricted_access?(%Scope{} = scope, scan) do
    Policy.allowed?(scope, :view_restricted_review, scan)
  end

  defp ensure_not_submitter(%Scan{submitted_by_id: account_id}, %Account{id: account_id}) do
    {:error, :conflict_of_interest}
  end

  defp ensure_not_submitter(_scan, _account), do: :ok

  defp ensure_moderation_hold_allows(scope, scan) do
    if Holds.scan_held?(scan.id) and not Policy.moderator?(scope) do
      {:error, :unauthorized}
    else
      :ok
    end
  end

  defp ensure_transition_allowed(%Scan{review_status: "rejected"}, "accepted"),
    do: {:error, :invalid_transition}

  defp ensure_transition_allowed(%Scan{} = scan, "accepted") do
    if FindingMemory.scan_verified?(scan), do: :ok, else: {:error, :verification_required}
  end

  defp ensure_transition_allowed(%Scan{review_status: status}, status), do: :ok
  defp ensure_transition_allowed(_scan, _status), do: :ok

  defp effective_status(:current, locked_scan), do: locked_scan.review_status
  defp effective_status(status, _locked_scan), do: status

  defp scan_state(scan), do: "#{scan.review_status}:#{scan.visibility}"

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp preload_record(scan_or_scans) do
    Repo.preload(
      scan_or_scans,
      [
        :repository,
        :submitted_by,
        :reviewed_by,
        findings: :canonical_finding,
        confirmations: :account
      ],
      force: true
    )
  end

  defp topic(repository_id), do: "repository:#{repository_id}"

  defp broadcast(repository_id, message) do
    Phoenix.PubSub.broadcast(Tarakan.PubSub, topic(repository_id), message)
  end
end
