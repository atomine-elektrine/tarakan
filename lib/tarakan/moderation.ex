defmodule Tarakan.Moderation do
  @moduledoc """
  Restricted abuse reports, reasoned moderation actions, and independent appeals.

  Reports never directly delete public history. Quarantine/redaction effects are
  handled by the owning domain while this context preserves the moderation trail.
  All moderation mutations re-authorize against fresh account state while holding
  database locks, and all participant reads avoid preloading private account data.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit
  alias Tarakan.Moderation.{Action, Appeal}
  alias Tarakan.Moderation.Case, as: ModerationCase
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans
  alias Tarakan.Scans.{Finding, Scan}
  alias Tarakan.Work
  alias Tarakan.Work.{Contribution, ReviewTask}

  @probation_report_limit 5
  @active_report_limit 20
  @open_statuses ~w(open in_review)
  @moderation_queue_limit 100

  @doc """
  Opens a restricted abuse report.

  Repeated reports by the same account for the same subject are idempotent while
  a report is open. Locking the reporter's account serializes quota checks so
  concurrent requests cannot exceed the rolling allowance.
  """
  def report(%Scope{} = scope, attrs) when is_map(attrs) do
    transact(fn ->
      fresh_scope = lock_scope!(scope)
      authorize_reporting_standing!(fresh_scope)
      authorize!(fresh_scope, :report_content, credential_preflight_subject(fresh_scope))
      subject = resolve_subject!(attrs)
      authorize_report_subject!(fresh_scope, subject)
      ensure_reportable!(fresh_scope, subject)

      case find_open_report(fresh_scope.account_id, subject) do
        %ModerationCase{} = existing ->
          existing

        nil ->
          enforce_report_limit!(fresh_scope)

          case_record =
            %ModerationCase{}
            |> ModerationCase.report_changeset(attrs)
            |> Ecto.Changeset.put_change(:reporter_id, fresh_scope.account_id)
            |> Ecto.Changeset.put_change(:subject_owner_id, subject.owner_id)
            |> Ecto.Changeset.put_change(:repository_id, subject.repository_id)
            |> insert!()

          record_audit!(fresh_scope, :moderation_report_opened, case_record, %{
            from_state: nil,
            to_state: "open",
            reason_code: case_record.reason
          })

          case_record
      end
    end)
  end

  def report(%Scope{}, _attrs), do: {:error, :invalid_report}
  def report(_scope, _attrs), do: {:error, :unauthorized}

  @doc "Returns a bounded oldest-first moderation queue to active moderators."
  def list_open(scope, opts \\ [])

  def list_open(%Scope{} = scope, opts) when is_list(opts) do
    with %Scope{} = fresh_scope <- refresh_scope(scope),
         :ok <- authorize_active_moderator(fresh_scope) do
      limit = queue_limit(Keyword.get(opts, :limit, @moderation_queue_limit))

      cases =
        ModerationCase
        |> where([case_record], case_record.status in ^@open_statuses)
        |> order_by([case_record], asc: case_record.inserted_at, asc: case_record.id)
        |> limit(^limit)
        |> preload([:actions, :appeals])
        |> Repo.all()

      {:ok, cases}
    end
  end

  def list_open(_scope, _opts), do: {:error, :unauthorized}

  @doc """
  Fetches a case for an active moderator or a directly involved participant.

  Unauthorized and missing cases deliberately have the same response. Participant
  views do not preload reporter, subject-owner, moderator, or action identities.
  """
  def get_case(%Scope{} = scope, id) do
    with %Scope{} = fresh_scope <- refresh_scope(scope),
         {:ok, id} <- normalize_id(id),
         %ModerationCase{} = case_record <- Repo.get(ModerationCase, id) do
      cond do
        active_moderator?(fresh_scope) ->
          {:ok, preload_case(case_record)}

        participant?(fresh_scope, case_record) ->
          {:ok, preload_participant_appeals(case_record, fresh_scope.account_id)}

        true ->
          {:error, :not_found}
      end
    else
      _other -> {:error, :not_found}
    end
  end

  def get_case(_scope, _id), do: {:error, :not_found}

  @doc "Claims an open case for independent moderator review."
  def assign(%Scope{} = scope, %ModerationCase{id: id}) when is_integer(id) do
    transact(fn ->
      fresh_scope = lock_active_moderator!(scope)
      case_record = lock_case!(id)
      ensure_independent_moderator!(fresh_scope, case_record)

      cond do
        case_record.status == "in_review" and
            case_record.assigned_to_id == fresh_scope.account_id ->
          preload_case(case_record)

        case_record.status == "open" ->
          case_record
          |> assign_case!(fresh_scope, "Assigned for independent moderator review.")
          |> preload_case()

        case_record.status == "in_review" and fresh_scope.platform_role == "admin" ->
          previous_assignee_id = case_record.assigned_to_id

          case_record
          |> assign_case!(
            fresh_scope,
            "Reassigned by an administrator to recover an active moderation case.",
            %{previous_assignee_id: previous_assignee_id}
          )
          |> preload_case()

        true ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  def assign(%Scope{}, %ModerationCase{}), do: {:error, :not_found}
  def assign(_scope, _case_record), do: {:error, :unauthorized}

  @doc "Resolves an assigned case. Only its independent assignee may decide it."
  def resolve(%Scope{} = scope, %ModerationCase{id: id}, disposition, reason)
      when is_integer(id) and disposition in ~w(resolved dismissed) do
    result =
      with {:ok, reason} <- normalize_reason(reason) do
        transact(fn ->
          fresh_scope = lock_active_moderator!(scope)
          case_record = lock_case!(id)
          ensure_independent_moderator!(fresh_scope, case_record)

          cond do
            idempotent_resolution?(case_record, fresh_scope, disposition, reason) ->
              preload_case(case_record)

            case_record.status != "in_review" ->
              Repo.rollback(:invalid_transition)

            case_record.assigned_to_id != fresh_scope.account_id ->
              Repo.rollback(:not_assigned)

            true ->
              action = if disposition == "resolved", do: "resolve", else: "dismiss"
              now = DateTime.utc_now()

              containment =
                if disposition == "resolved" do
                  contain_subject!(fresh_scope, case_record, reason)
                else
                  :none
                end

              updated =
                case_record
                |> Ecto.Changeset.change(
                  status: disposition,
                  resolution: reason,
                  resolved_by_id: fresh_scope.account_id,
                  resolved_at: now
                )
                |> update!()

              insert_action!(updated, fresh_scope, action, reason)

              if containment != :none do
                insert_action!(updated, fresh_scope, "quarantine", reason, containment)
              end

              record_audit!(fresh_scope, :moderation_case_decided, updated, %{
                from_state: "in_review",
                to_state: disposition,
                reason_code: action
              })

              preload_case(updated)
          end
        end)
      end

    maybe_broadcast_resolution(result, disposition)
  end

  def resolve(%Scope{}, %ModerationCase{}, disposition, _reason)
      when disposition not in ~w(resolved dismissed),
      do: {:error, :invalid_disposition}

  def resolve(%Scope{}, %ModerationCase{}, _disposition, _reason), do: {:error, :not_found}
  def resolve(_scope, _case_record, _disposition, _reason), do: {:error, :unauthorized}

  @doc "Appeals a resolved moderation decision as its subject or repository steward."
  def appeal(%Scope{} = scope, %ModerationCase{id: id}, attrs)
      when is_integer(id) and is_map(attrs) do
    transact(fn ->
      fresh_scope = lock_scope!(scope)
      authorize_reporting_standing!(fresh_scope)
      authorize!(fresh_scope, :appeal_moderation, credential_preflight_subject(fresh_scope))
      case_record = lock_case!(id)
      authorize_appeal_subject!(fresh_scope, case_record)
      ensure_appellant!(fresh_scope, case_record)

      case find_appeal(case_record.id, fresh_scope.account_id, lock: true) do
        %Appeal{} = existing ->
          Repo.preload(existing, :moderation_case)

        nil ->
          if case_record.status != "resolved", do: Repo.rollback(:not_appealable)

          appeal =
            %Appeal{}
            |> Appeal.changeset(attrs)
            |> Ecto.Changeset.put_change(:moderation_case_id, case_record.id)
            |> Ecto.Changeset.put_change(:appellant_id, fresh_scope.account_id)
            |> insert!()

          record_audit!(fresh_scope, :moderation_appeal_opened, case_record, %{
            from_state: "resolved",
            to_state: "appealed"
          })

          Repo.preload(appeal, :moderation_case)
      end
    end)
  end

  def appeal(%Scope{}, %ModerationCase{}, _attrs), do: {:error, :invalid_appeal}
  def appeal(_scope, _case_record, _attrs), do: {:error, :unauthorized}

  @doc "Decides an appeal with a moderator independent of every party and resolver."
  def decide_appeal(%Scope{} = scope, %Appeal{id: id}, status, reason)
      when is_integer(id) and status in ~w(upheld denied) do
    with {:ok, reason} <- normalize_reason(reason) do
      transact(fn ->
        fresh_scope = lock_active_moderator!(scope)
        appeal = lock_appeal!(id)
        case_record = lock_case!(appeal.moderation_case_id)
        authorize!(fresh_scope, :moderate, case_record)
        ensure_independent_appeal_moderator!(fresh_scope, case_record, appeal)

        cond do
          idempotent_appeal_decision?(appeal, fresh_scope, status, reason) ->
            Repo.preload(appeal, :moderation_case)

          appeal.status != "open" ->
            Repo.rollback(:already_decided)

          case_record.status != "resolved" ->
            Repo.rollback(:invalid_transition)

          true ->
            decided =
              appeal
              |> Appeal.decision_changeset(status, reason, fresh_scope.account)
              |> update!()

            action = if status == "upheld", do: "appeal_upheld", else: "appeal_denied"

            updated_case =
              if status == "upheld" do
                case_record
                |> Ecto.Changeset.change(status: "overturned")
                |> update!()
              else
                case_record
              end

            insert_action!(updated_case, fresh_scope, action, reason)

            record_audit!(fresh_scope, :moderation_appeal_decided, updated_case, %{
              from_state: "resolved",
              to_state: if(status == "upheld", do: "overturned", else: "resolved"),
              reason_code: action
            })

            Repo.preload(decided, :moderation_case, force: true)
        end
      end)
    end
  end

  def decide_appeal(%Scope{}, %Appeal{}, status, _reason)
      when status not in ~w(upheld denied),
      do: {:error, :invalid_decision}

  def decide_appeal(%Scope{}, %Appeal{}, _status, _reason), do: {:error, :not_found}
  def decide_appeal(_scope, _appeal, _status, _reason), do: {:error, :unauthorized}

  defp assign_case!(case_record, scope, reason, metadata \\ %{}) do
    from_state = case_record.status

    updated =
      case_record
      |> Ecto.Changeset.change(status: "in_review", assigned_to_id: scope.account_id)
      |> update!()

    insert_action!(updated, scope, "assign", reason, metadata)

    record_audit!(scope, :moderation_case_assigned, updated, %{
      from_state: from_state,
      to_state: "in_review",
      reason_code: "assign",
      metadata: metadata
    })

    updated
  end

  defp insert_action!(case_record, scope, action, reason, metadata \\ %{}) do
    %Action{}
    |> Action.changeset(%{action: action, reason: reason, metadata: metadata})
    |> Ecto.Changeset.put_change(:moderation_case_id, case_record.id)
    |> Ecto.Changeset.put_change(:actor_id, scope.account_id)
    |> insert!()
  end

  defp contain_subject!(scope, %ModerationCase{subject_type: "scan", subject_id: id}, reason) do
    scan = Repo.get(Scan, id) || Repo.rollback(:subject_not_found)
    contain_scan!(scope, scan, reason)
  end

  defp contain_subject!(
         scope,
         %ModerationCase{subject_type: "finding", subject_id: id},
         reason
       ) do
    scan =
      Repo.one(
        from finding in Finding,
          join: scan in assoc(finding, :scan),
          where: finding.id == ^id,
          select: scan
      ) || Repo.rollback(:subject_not_found)

    contain_scan!(scope, scan, reason)
  end

  defp contain_subject!(
         scope,
         %ModerationCase{subject_type: "review_task", subject_id: id},
         reason
       ) do
    task = Repo.get(ReviewTask, id) || Repo.rollback(:subject_not_found)
    contain_task!(scope, task, reason)
  end

  defp contain_subject!(
         scope,
         %ModerationCase{subject_type: "contribution", subject_id: id},
         reason
       ) do
    task =
      Repo.one(
        from contribution in Contribution,
          join: task in assoc(contribution, :review_task),
          where: contribution.id == ^id,
          select: task
      ) || Repo.rollback(:subject_not_found)

    contain_task!(scope, task, reason)
  end

  defp contain_subject!(
         scope,
         %ModerationCase{subject_type: "repository", subject_id: id},
         _reason
       ) do
    repository = Repo.get(Repository, id) || Repo.rollback(:subject_not_found)

    case Repositories.update_participation_mode(scope, repository, %{participation_mode: "paused"}) do
      {:ok, paused_repository} ->
        case Repositories.update_listing_status(scope, paused_repository, "quarantined") do
          {:ok, _repository} ->
            %{
              subject_type: "repository",
              remedy: "paused_quarantined",
              repository_id: repository.id
            }

          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp contain_subject!(
         scope,
         %ModerationCase{subject_type: "account", subject_id: account_id},
         _reason
       ) do
    account =
      Repo.one(
        from candidate in Account,
          where: candidate.id == ^account_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:subject_not_found)

    if account.platform_role == "admin" and not Policy.admin?(scope) do
      Repo.rollback(:unauthorized)
    end

    contained_state =
      if account.state in ["suspended", "banned"], do: account.state, else: "restricted"

    updated =
      account
      |> Ecto.Changeset.change(state: contained_state)
      |> update!()

    %{
      subject_type: "account",
      remedy: "account_restricted",
      account_id: updated.id,
      from_state: account.state,
      to_state: updated.state
    }
  end

  defp contain_scan!(scope, scan, reason) do
    attrs = %{
      "moderation_reason" => "abuse_report_resolved",
      "moderation_notes" => reason
    }

    case Scans.contest_scan(scope, scan, attrs) do
      {:ok, _scan} -> %{subject_type: "scan", remedy: "contested_restricted", scan_id: scan.id}
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp contain_task!(scope, task, reason) do
    case Work.quarantine_task(task, scope, reason) do
      {:ok, _task} -> %{subject_type: "review_task", remedy: "cancelled", task_id: task.id}
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp maybe_broadcast_resolution({:ok, case_record} = result, "resolved") do
    broadcast_containment(case_record)
    result
  end

  defp maybe_broadcast_resolution(result, _disposition), do: result

  defp broadcast_containment(%ModerationCase{subject_type: "scan", subject_id: id}) do
    with %Scan{} = scan <- Repo.get(Scan, id) do
      Scans.broadcast_refresh(scan)
      broadcast_repository_refresh(scan.repository_id)
    end
  end

  defp broadcast_containment(%ModerationCase{subject_type: "finding", subject_id: id}) do
    case Repo.one(
           from finding in Finding,
             join: scan in assoc(finding, :scan),
             where: finding.id == ^id,
             select: scan
         ) do
      %Scan{} = scan ->
        Scans.broadcast_refresh(scan)
        broadcast_repository_refresh(scan.repository_id)

      nil ->
        :ok
    end
  end

  defp broadcast_containment(%ModerationCase{subject_type: "review_task", subject_id: id}) do
    with %ReviewTask{} = task <- Repo.get(ReviewTask, id), do: Work.broadcast_refresh(task)
  end

  defp broadcast_containment(%ModerationCase{subject_type: "contribution", subject_id: id}) do
    case Repo.one(
           from contribution in Contribution,
             join: task in assoc(contribution, :review_task),
             where: contribution.id == ^id,
             select: task
         ) do
      %ReviewTask{} = task -> Work.broadcast_refresh(task)
      nil -> :ok
    end
  end

  defp broadcast_containment(%ModerationCase{subject_type: "repository", subject_id: id}) do
    with %Repository{} = repository <- Repo.get(Repository, id) do
      Repositories.broadcast_record_updated(repository)
      Work.broadcast_repository_refresh(repository.id)
    end
  end

  defp broadcast_containment(%ModerationCase{subject_type: "account", subject_id: id}) do
    _revalidation = Scans.revalidate_account_authority(id)

    case Repo.get(Account, id) do
      %Account{state: state} when state in ["suspended", "banned"] ->
        Accounts.invalidate_account_access(id, purge_credentials: state == "banned")

      _other ->
        Accounts.broadcast_authorization_changed(id)
    end
  end

  defp broadcast_containment(_case_record), do: :ok

  defp broadcast_repository_refresh(repository_id) do
    with %Repository{} = repository <- Repo.get(Repository, repository_id),
         do: Repositories.broadcast_record_updated(repository)
  end

  defp record_audit!(scope, action, subject, attrs) do
    case Audit.record(scope, action, subject, attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_reporting_standing!(%Scope{account_id: account_id, account_state: state})
       when is_integer(account_id) and state in ["probation", "active", "restricted"],
       do: :ok

  defp authorize_reporting_standing!(_scope), do: Repo.rollback(:unauthorized)

  defp authorize_active_moderator(%Scope{account_state: "active"} = scope),
    do: Policy.authorize(scope, :moderate, nil)

  defp authorize_active_moderator(_scope), do: {:error, :unauthorized}

  defp active_moderator?(%Scope{} = scope), do: authorize_active_moderator(scope) == :ok

  defp lock_active_moderator!(scope) do
    fresh_scope = lock_scope!(scope)

    case authorize_active_moderator(fresh_scope) do
      :ok -> fresh_scope
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_scope!(%Scope{account_id: account_id} = scope) when is_integer(account_id) do
    account =
      Repo.one(
        from candidate in Account,
          where: candidate.id == ^account_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:unauthorized)

    case Accounts.refresh_scope_for_account(account, scope) do
      {:ok, fresh_scope} -> fresh_scope
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_scope!(_scope), do: Repo.rollback(:unauthorized)

  defp refresh_scope(%Scope{account_id: account_id} = scope) when is_integer(account_id) do
    case Accounts.get_account(account_id) do
      %Account{} = account ->
        case Accounts.refresh_scope_for_account(account, scope) do
          {:ok, fresh_scope} -> fresh_scope
          {:error, _reason} -> nil
        end

      nil ->
        nil
    end
  end

  defp refresh_scope(%Scope{}), do: nil

  defp authorize!(scope, action, subject) do
    case Policy.authorize(scope, action, subject) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_report_subject!(scope, subject) do
    case Policy.authorize(scope, :report_content, authorization_subject(subject)) do
      :ok -> :ok
      {:error, _reason} -> Repo.rollback(:subject_not_found)
    end
  end

  defp authorize_appeal_subject!(scope, case_record) do
    case Policy.authorize(scope, :appeal_moderation, case_record) do
      :ok -> :ok
      {:error, _reason} -> Repo.rollback(:not_found)
    end
  end

  defp ensure_independent_moderator!(scope, case_record) do
    if scope.account_id in [case_record.reporter_id, case_record.subject_owner_id] do
      Repo.rollback(:conflict_of_interest)
    end

    :ok
  end

  defp ensure_independent_appeal_moderator!(scope, case_record, appeal) do
    conflicts = [
      case_record.reporter_id,
      case_record.subject_owner_id,
      case_record.resolved_by_id,
      appeal.appellant_id
    ]

    if scope.account_id in conflicts do
      Repo.rollback(:conflict_of_interest)
    end

    :ok
  end

  defp ensure_appellant!(scope, case_record) do
    if case_record.subject_owner_id == scope.account_id or
         Policy.repository_steward?(scope, case_record) do
      :ok
    else
      Repo.rollback(:not_found)
    end
  end

  defp participant?(%Scope{account_id: account_id} = scope, case_record)
       when is_integer(account_id) do
    participant_credential_allows?(scope, case_record) and
      (account_id in [case_record.reporter_id, case_record.subject_owner_id] or
         Policy.repository_steward?(scope, case_record))
  end

  defp participant?(_scope, _case_record), do: false

  defp idempotent_resolution?(case_record, scope, disposition, reason) do
    case_record.status == disposition and case_record.resolved_by_id == scope.account_id and
      case_record.resolution == reason
  end

  defp idempotent_appeal_decision?(appeal, scope, status, reason) do
    appeal.status == status and appeal.decided_by_id == scope.account_id and
      appeal.decision_reason == reason
  end

  defp enforce_report_limit!(scope) do
    limit = report_limit(scope)
    since = DateTime.add(DateTime.utc_now(), -1, :day)

    count =
      Repo.aggregate(
        from(case_record in ModerationCase,
          where:
            case_record.reporter_id == ^scope.account_id and
              case_record.inserted_at >= ^since
        ),
        :count
      )

    if count >= limit, do: Repo.rollback(:rate_limited), else: :ok
  end

  defp report_limit(%Scope{account_state: "active"}), do: @active_report_limit
  defp report_limit(%Scope{}), do: @probation_report_limit

  defp find_open_report(reporter_id, subject) do
    Repo.one(
      from case_record in ModerationCase,
        where:
          case_record.reporter_id == ^reporter_id and
            case_record.subject_type == ^subject.type and
            case_record.subject_id == ^subject.id and
            case_record.status in ^@open_statuses,
        limit: 1
    )
  end

  defp find_appeal(case_id, appellant_id, opts) do
    query =
      from appeal in Appeal,
        where: appeal.moderation_case_id == ^case_id and appeal.appellant_id == ^appellant_id

    query = if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp resolve_subject!(attrs) do
    subject_type = get_attr(attrs, :subject_type)
    subject_id = get_attr(attrs, :subject_id)

    with true <- is_binary(subject_type),
         {:ok, subject_id} <- normalize_id(subject_id),
         {:ok, subject} <- fetch_subject(subject_type, subject_id) do
      subject
    else
      _other -> Repo.rollback(:subject_not_found)
    end
  end

  defp fetch_subject("repository", id) do
    case Repo.get(Repository, id) do
      nil -> {:error, :subject_not_found}
      repository -> {:ok, subject("repository", repository, id, id, nil)}
    end
  end

  defp fetch_subject("account", id) do
    case Accounts.get_account(id) do
      nil -> {:error, :subject_not_found}
      account -> {:ok, subject("account", account, id, nil, id)}
    end
  end

  defp fetch_subject("scan", id) do
    case Repo.get(Scan, id) do
      nil -> {:error, :subject_not_found}
      scan -> {:ok, subject("scan", scan, id, scan.repository_id, scan.submitted_by_id)}
    end
  end

  defp fetch_subject("finding", id) do
    query =
      from finding in Finding,
        join: scan in assoc(finding, :scan),
        where: finding.id == ^id,
        select: {finding, scan}

    case Repo.one(query) do
      nil ->
        {:error, :subject_not_found}

      {finding, scan} ->
        {:ok, subject("finding", finding, id, scan.repository_id, scan.submitted_by_id, scan)}
    end
  end

  defp fetch_subject("review_task", id) do
    case Repo.get(ReviewTask, id) do
      nil ->
        {:error, :subject_not_found}

      task ->
        {:ok, subject("review_task", task, id, task.repository_id, task.created_by_id)}
    end
  end

  defp fetch_subject("contribution", id) do
    query =
      from contribution in Contribution,
        join: task in assoc(contribution, :review_task),
        where: contribution.id == ^id,
        select: {contribution, task}

    case Repo.one(query) do
      nil ->
        {:error, :subject_not_found}

      {contribution, task} ->
        {:ok,
         subject(
           "contribution",
           contribution,
           id,
           task.repository_id,
           contribution.account_id,
           task
         )}
    end
  end

  defp fetch_subject(_type, _id), do: {:error, :subject_not_found}

  defp subject(type, record, id, repository_id, owner_id, access_record \\ nil) do
    %{
      type: type,
      record: record,
      id: id,
      repository_id: repository_id,
      owner_id: owner_id,
      access_record: access_record || record
    }
  end

  defp authorization_subject(subject) do
    %{repository_id: subject.repository_id, account_id: subject.owner_id}
  end

  defp credential_preflight_subject(%Scope{token_repository_id: repository_id})
       when is_integer(repository_id),
       do: %{repository_id: repository_id}

  defp credential_preflight_subject(%Scope{}), do: nil

  defp participant_credential_allows?(scope, case_record) do
    Scope.token_scope?(scope, "reports:write") and
      (is_nil(scope.token_repository_id) or scope.token_repository_id == case_record.repository_id)
  end

  defp ensure_reportable!(scope, subject) do
    if reportable?(scope, subject), do: :ok, else: Repo.rollback(:subject_not_found)
  end

  defp reportable?(scope, %{type: "repository", record: repository}) do
    repository.listing_status == "listed" or repository.submitted_by_id == scope.account_id or
      Policy.moderator?(scope) or Policy.repository_reviewer?(scope, repository)
  end

  defp reportable?(_scope, %{type: "account"}), do: true

  defp reportable?(scope, %{type: "scan", record: scan, owner_id: owner_id}) do
    owner_id == scope.account_id or
      (public_repository?(scan.repository_id) and Scan.publicly_listed?(scan)) or
      Policy.allowed?(scope, :view_restricted_review, scan)
  end

  defp reportable?(scope, %{type: "finding", access_record: scan, owner_id: owner_id}) do
    owner_id == scope.account_id or
      (public_repository?(scan.repository_id) and scan.review_status == "accepted" and
         scan.visibility == "public") or
      Policy.allowed?(scope, :view_restricted_review, scan)
  end

  defp reportable?(scope, %{type: "review_task", record: task, owner_id: owner_id}) do
    owner_id == scope.account_id or
      (public_repository?(task.repository_id) and ReviewTask.public?(task)) or
      Policy.allowed?(scope, :view_restricted_task, task)
  end

  defp reportable?(scope, %{type: "contribution", access_record: task, owner_id: owner_id}) do
    owner_id == scope.account_id or
      (public_repository?(task.repository_id) and ReviewTask.public?(task)) or
      Policy.allowed?(scope, :view_restricted_task, task)
  end

  defp reportable?(_scope, _subject), do: false

  defp public_repository?(repository_id) when is_integer(repository_id) do
    Repo.exists?(
      from repository in Repository,
        where: repository.id == ^repository_id and repository.listing_status == "listed"
    )
  end

  defp public_repository?(_repository_id), do: false

  defp lock_case!(id) do
    Repo.one(
      from case_record in ModerationCase,
        where: case_record.id == ^id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp lock_appeal!(id) do
    Repo.one(from appeal in Appeal, where: appeal.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)

    if String.length(reason) in 10..2_000 do
      {:ok, reason}
    else
      {:error, :invalid_reason}
    end
  end

  defp normalize_reason(_reason), do: {:error, :invalid_reason}

  defp normalize_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, :invalid_id}
    end
  end

  defp normalize_id(_id), do: {:error, :invalid_id}

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp queue_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(200)
  defp queue_limit(_limit), do: @moderation_queue_limit

  defp preload_participant_appeals(case_record, account_id) do
    own_appeals = from appeal in Appeal, where: appeal.appellant_id == ^account_id
    Repo.preload(case_record, appeals: own_appeals)
  end

  defp preload_case(case_record) do
    Repo.preload(
      case_record,
      [:actions, :appeals],
      force: true
    )
  end
end
