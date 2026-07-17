defmodule Tarakan.Work do
  @moduledoc """
  The commit-pinned security work queue.

  Tasks and contributions are public from the moment they exist; workflow
  states (proposed, claimed, submitted, accepted) are labels and claim gates,
  never disclosure gates. Only a moderation quarantine restricts content.
  Every transition is checked again while holding database row locks so
  concurrent requests cannot bypass lifecycle invariants.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Activity
  alias Tarakan.Audit
  alias Tarakan.GitHub
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.Reputation.Stake
  alias Tarakan.Scans
  alias Tarakan.Scans.Scan
  alias Tarakan.Work.{Contribution, ReviewDecision, ReviewTask}

  @claim_seconds 2 * 60 * 60
  @claim_mutation_limit 30
  @claim_mutation_window_seconds 60
  @finding_kinds ~w(code_review threat_model privacy_review business_logic)

  def subscribe(repository_id) do
    Phoenix.PubSub.subscribe(Tarakan.PubSub, topic(repository_id))
  end

  @doc "Broadcasts a committed task-state refresh to subscribed views."
  def broadcast_refresh(%ReviewTask{} = task) do
    broadcast(task.repository_id, {:review_task_updated, task.id})
    :ok
  end

  @doc "Refreshes every connected task view for a repository listing change."
  def broadcast_repository_refresh(repository_id) when is_integer(repository_id) do
    ReviewTask
    |> where([task], task.repository_id == ^repository_id)
    |> select([task], task.id)
    |> Repo.all()
    |> Enum.each(&broadcast(repository_id, {:review_task_updated, &1}))

    :ok
  end

  def kinds, do: ReviewTask.kinds()
  def capabilities, do: ReviewTask.capabilities()
  def provenances, do: Contribution.provenances()

  @doc "Lists tasks visible to the supplied scope, or only public tasks by default."
  def list_tasks(repository, opts \\ [])

  def list_tasks(%Repository{id: repository_id} = repository, opts) do
    scope = Keyword.get(opts, :scope)

    ReviewTask
    |> where([task], task.repository_id == ^repository_id)
    |> visible_to(scope, repository)
    |> maybe_active_only(Keyword.get(opts, :active_only, false))
    |> order_by(
      [task],
      asc:
        fragment(
          "CASE ? WHEN 'open' THEN 0 WHEN 'claimed' THEN 1 WHEN 'accepted' THEN 2 ELSE 3 END",
          task.status
        ),
      desc: task.inserted_at,
      desc: task.id
    )
    |> maybe_limit(Keyword.get(opts, :limit))
    |> Repo.all()
    |> preload_task()
    |> Enum.map(&expose_task(&1, scope))
  end

  @doc """
  Claimable public jobs across listed repositories, newest first.

  Uses the anonymous visibility rule: listed repository, claimable status
  (`open` / `changes_requested`), public visibility. Safe for logged-out
  visitors and sitemap discovery.
  """
  def list_open_public_tasks(limit \\ 6) when is_integer(limit) and limit > 0 do
    limit = limit |> max(1) |> min(100)
    claimable = ReviewTask.claimable_statuses()

    ReviewTask
    |> join(:inner, [task], repository in assoc(task, :repository))
    |> where(
      [task, repository],
      repository.listing_status == "listed" and task.status in ^claimable and
        task.visibility in ["public_summary", "public"]
    )
    |> order_by([task], desc: task.inserted_at, desc: task.id)
    |> limit(^limit)
    |> preload([:repository, :created_by])
    |> Repo.all()
  end

  @doc """
  Compact rows for the sitemap: public claimable jobs on listed repositories.
  """
  def list_indexable_public_tasks(limit \\ 2_000) when is_integer(limit) and limit > 0 do
    limit = min(limit, 5_000)
    claimable = ReviewTask.claimable_statuses()

    ReviewTask
    |> join(:inner, [task], repository in assoc(task, :repository))
    |> where(
      [task, repository],
      repository.listing_status == "listed" and task.status in ^claimable and
        task.visibility in ["public_summary", "public"]
    )
    |> order_by([task], desc: task.updated_at, desc: task.id)
    |> limit(^limit)
    |> select([task], %{id: task.id, updated_at: task.updated_at})
    |> Repo.all()
  end

  @doc """
  Global Jobs queue for API clients.

  Always includes open / changes_requested public jobs on listed repositories.
  When `account_id:` is set, also includes that account's **active claims**
  (`status=claimed` with unexpired lease) so a client can keep working after
  claim without the job vanishing from the queue.
  """
  def list_open_claimable_tasks(opts \\ []) when is_list(opts) do
    limit =
      opts
      |> Keyword.get(:limit, 50)
      |> max(1)
      |> min(100)

    account_id = Keyword.get(opts, :account_id)
    now = DateTime.utc_now()
    claimable = ReviewTask.claimable_statuses()

    base =
      ReviewTask
      |> join(:inner, [task], repository in assoc(task, :repository))
      |> where(
        [task, repository],
        repository.listing_status == "listed" and
          task.visibility in ["public_summary", "public"]
      )

    base =
      if is_integer(account_id) do
        where(
          base,
          [task, _repository],
          task.status in ^claimable or
            (task.status == "claimed" and task.claimed_by_id == ^account_id and
               not is_nil(task.claim_expires_at) and task.claim_expires_at > ^now)
        )
      else
        where(base, [task, _repository], task.status in ^claimable)
      end

    base
    |> order_by(
      [task],
      asc:
        fragment(
          "CASE ? WHEN 'claimed' THEN 0 WHEN 'open' THEN 1 WHEN 'changes_requested' THEN 2 ELSE 3 END",
          task.status
        ),
      desc: task.inserted_at,
      desc: task.id
    )
    |> limit(^limit)
    |> Repo.all()
    |> preload_task()
  end

  def get_task!(id), do: ReviewTask |> Repo.get!(id) |> preload_task()

  def get_task(id) do
    case Repo.get(ReviewTask, id) do
      nil -> nil
      task -> preload_task(task)
    end
  end

  @doc "Returns a task only when it is public or visible to the supplied scope."
  def get_visible_task(id, scope \\ nil) do
    case get_task(id) do
      nil -> nil
      task -> if visible_to_scope?(task, scope), do: expose_task(task, scope)
    end
  end

  def change_task(%ReviewTask{} = task \\ %ReviewTask{}, attrs \\ %{}) do
    ReviewTask.creation_changeset(task, attrs)
  end

  def change_contribution(%Contribution{} = contribution \\ %Contribution{}, attrs \\ %{}) do
    Contribution.changeset(contribution, attrs)
  end

  def create_task(%Repository{} = repository, %Account{} = creator, attrs) do
    create_task(repository, Scope.for_account(creator), attrs)
  end

  def create_task(
        %Repository{} = repository,
        %Scope{account: %Account{} = creator} = scope,
        attrs
      ) do
    repository = Repo.get!(Repository, repository.id)

    changeset =
      %ReviewTask{}
      |> ReviewTask.creation_changeset(attrs)
      |> Ecto.Changeset.put_change(:repository_id, repository.id)
      |> Ecto.Changeset.put_change(:created_by_id, creator.id)
      |> Ecto.Changeset.put_change(:status, "proposed")

    with :ok <- authorize(scope, :propose_task, repository),
         {:ok, changeset} <- valid_changeset(changeset),
         :ok <- ensure_target_review_on_repository(changeset, repository),
         :ok <- proposal_quota_precheck(scope),
         :ok <- proposal_preflight(scope, repository),
         {:ok, commit} <- verify_commit(repository, changeset) do
      changeset =
        Ecto.Changeset.put_change(
          changeset,
          :commit_committed_at,
          normalize_precision(commit.committed_at)
        )

      result =
        Repo.transaction(fn ->
          locked_repository = lock_repository!(repository.id)
          fresh_scope = lock_scope_account(scope)
          authorize_locked!(fresh_scope, :propose_task, locked_repository)
          enforce_proposal_quota!(fresh_scope)

          case Repo.insert(changeset) do
            {:ok, task} ->
              record_audit(fresh_scope, :review_task_created, task, nil)
              preload_task(task)

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, task} ->
          broadcast(repository.id, {:review_task_created, task.id})
          {:ok, task}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def create_task(%Repository{}, _actor, _attrs), do: {:error, :unauthorized}

  def publish_task(%ReviewTask{} = task, %Account{} = account, attrs) do
    publish_task(task, Scope.for_account(account), attrs)
  end

  def publish_task(%ReviewTask{} = task, %Scope{account: %Account{} = account} = scope, attrs) do
    with :ok <- authorize(scope, :publish_task, task),
         :ok <- verify_disclosure_identity(task),
         {:ok, decision_changeset} <- decision_changeset("publish", attrs) do
      transition(task, scope, :review_task_published, :publish_task, fn locked, fresh_scope ->
        # Repo stewards/owners and platform moderators may publish, including Jobs
        # they proposed. Spam is gated by :publish_task policy (not mere membership).
        cond do
          locked.status != "proposed" ->
            Repo.rollback(:invalid_state)

          true ->
            insert_decision!(decision_changeset, locked, account)

            now = DateTime.utc_now()
            repository = promote_pending_repository!(locked.repository, fresh_scope)
            locked = %{locked | repository: repository}

            locked
            |> Ecto.Changeset.change(
              status: "open",
              visibility: "public",
              published_at: now,
              disclosed_at: now,
              disclosed_by_id: account.id
            )
            |> Repo.update!()
        end
      end)
    end
  end

  def publish_task(%ReviewTask{}, _actor, _attrs), do: {:error, :unauthorized}

  def claim_task(%ReviewTask{} = task, %Account{} = account) do
    claim_task(task, Scope.for_account(account))
  end

  def claim_task(%ReviewTask{} = task, %Scope{account: %Account{} = account} = scope) do
    with :ok <- authorize(scope, :claim_task, task),
         :ok <- claim_mutation_preflight(scope) do
      transition(task, scope, :review_task_updated, :claim_task, fn locked, fresh_scope ->
        # Creators may claim and perform their own Jobs (solo/hosted workflows).
        # Independent review of *submitted* work is still enforced elsewhere.
        cond do
          ReviewTask.claim_active?(locked) and locked.claimed_by_id == account.id ->
            {:noop, locked}

          ReviewTask.claim_active?(locked) ->
            Repo.rollback(:already_claimed)

          not claimable_now?(locked) ->
            Repo.rollback(if(ReviewTask.terminal?(locked), do: :closed, else: :not_open))

          active_claim_count(account.id) >= claim_limit(fresh_scope.account) ->
            Repo.rollback(:claim_limit)

          true ->
            now = DateTime.utc_now()

            locked
            |> Ecto.Changeset.change(
              status: "claimed",
              visibility: "public",
              claimed_by_id: account.id,
              claimed_at: now,
              claim_expires_at: DateTime.add(now, @claim_seconds, :second)
            )
            |> Repo.update!()
        end
      end)
    end
  end

  def claim_task(%ReviewTask{}, _actor), do: {:error, :unauthorized}

  def release_task(%ReviewTask{} = task, %Account{} = account) do
    release_task(task, Scope.for_account(account))
  end

  def release_task(%ReviewTask{} = task, %Scope{account: %Account{} = account} = scope) do
    with :ok <- authorize(scope, :claim_task, task),
         :ok <- claim_mutation_preflight(scope) do
      transition(task, scope, :review_task_updated, :claim_task, fn locked, _fresh_scope ->
        cond do
          ReviewTask.terminal?(locked) ->
            Repo.rollback(:closed)

          locked.status == "claimed" and locked.claimed_by_id == account.id ->
            next_status = release_status(locked)

            locked
            |> Ecto.Changeset.change(
              status: next_status,
              visibility: "public",
              claimed_by_id: nil,
              claimed_at: nil,
              claim_expires_at: nil
            )
            |> Repo.update!()

          true ->
            Repo.rollback(:not_claimant)
        end
      end)
    end
  end

  def release_task(%ReviewTask{}, _actor), do: {:error, :unauthorized}

  @doc "Extends an active claim held by the caller for another lease window."
  def renew_claim(%ReviewTask{} = task, %Account{} = account) do
    renew_claim(task, Scope.for_account(account))
  end

  def renew_claim(%ReviewTask{} = task, %Scope{account: %Account{} = account} = scope) do
    with :ok <- authorize(scope, :claim_task, task),
         :ok <- claim_mutation_preflight(scope) do
      transition(task, scope, :review_task_updated, :claim_task, fn locked, _fresh_scope ->
        cond do
          locked.status != "claimed" or locked.claimed_by_id != account.id ->
            Repo.rollback(:not_claimant)

          not ReviewTask.claim_active?(locked) ->
            Repo.rollback(:claim_expired)

          true ->
            locked
            |> Ecto.Changeset.change(
              claim_expires_at: DateTime.add(DateTime.utc_now(), @claim_seconds, :second)
            )
            |> Repo.update!()
        end
      end)
    end
  end

  def renew_claim(%ReviewTask{}, _actor), do: {:error, :unauthorized}

  @doc """
  Submits evidence for independent review; it does not accept the task.

  Finding-kind Requests with a Tarakan Review/Scan Format `document` create a
  linked Review (findings). Legacy prose (`summary` + `evidence`) remains when
  `:request_completion_mode` is `:document_or_legacy_prose` and no document is
  present. See design docs/designs/2026-07-12-review-request-domain-collapse.md.
  """
  def submit_task(%ReviewTask{} = task, %Account{} = account, attrs) do
    submit_task(task, Scope.for_account(account), attrs)
  end

  def submit_task(%ReviewTask{} = task, %Scope{account: %Account{} = account} = scope, attrs)
      when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- authorize(scope, :submit_contribution, task),
         {:ok, path} <- classify_complete_path(task, attrs) do
      case path do
        :review -> submit_task_with_review(task, scope, account, attrs)
        :verdict -> submit_task_with_verdict(task, scope, account, attrs)
        :legacy_prose -> submit_task_legacy_prose(task, scope, account, attrs)
      end
    end
  end

  def submit_task(%ReviewTask{}, _actor, _attrs), do: {:error, :unauthorized}

  defp classify_complete_path(%ReviewTask{kind: kind} = task, attrs) do
    document? = document_present?(attrs)
    mode = request_completion_mode()
    verdict? = verdict_present?(attrs)

    cond do
      kind == "verify_findings" and not is_nil(task.target_review_id) and verdict? ->
        {:ok, :verdict}

      kind == "verify_findings" and not is_nil(task.target_review_id) and document? ->
        {:error, :document_not_allowed}

      kind == "verify_findings" and not is_nil(task.target_review_id) ->
        {:error, :verdict_required}

      # Grandfathered verify_findings without target_review_id: prose only.
      kind == "verify_findings" and document? ->
        {:error, :document_not_allowed}

      kind == "verify_findings" ->
        {:ok, :legacy_prose}

      kind == "write_fix" and document? ->
        {:error, :document_not_allowed}

      kind == "write_fix" ->
        {:ok, :legacy_prose}

      kind in @finding_kinds and document? ->
        {:ok, :review}

      kind in @finding_kinds and mode == :document_required ->
        {:error, :document_required}

      kind in @finding_kinds ->
        # Dual mode: attempt legacy prose so incomplete fields return changeset errors.
        {:ok, :legacy_prose}

      true ->
        {:error, :invalid_state}
    end
  end

  defp verdict_present?(attrs) do
    case attrs |> Map.get("verdict", "") |> to_string() |> String.downcase() |> String.trim() do
      v when v in ["confirmed", "disputed"] -> true
      _ -> false
    end
  end

  defp document_present?(attrs) do
    case Map.get(attrs, "document") do
      nil -> false
      "" -> false
      doc when is_map(doc) -> true
      doc when is_binary(doc) -> String.trim(doc) != ""
      _other -> false
    end
  end

  defp request_completion_mode do
    Application.get_env(:tarakan, :request_completion_mode, :document_or_legacy_prose)
  end

  defp submit_task_with_verdict(task, scope, _account, attrs) do
    with {:ok, prepared} <- prepare_verdict_attrs(attrs) do
      result =
        Repo.transaction(fn ->
          locked_repository = lock_repository!(task.repository_id)
          fresh_scope = lock_scope_account(scope)
          locked = locked_task!(task.id)

          if locked.repository_id != locked_repository.id, do: Repo.rollback(:invalid_state)
          if is_nil(locked.target_review_id), do: Repo.rollback(:target_review_required)

          locked = %{locked | repository: locked_repository}
          authorize_locked!(fresh_scope, :submit_contribution, locked)
          assert_active_claimant!(locked, fresh_scope.account)

          if not contribution_satisfies_capability?(locked.capability, prepared.provenance) do
            Repo.rollback(:capability_mismatch)
          end

          case Scans.stage_confirmation(
                 fresh_scope,
                 locked.target_review_id,
                 prepared.confirmation_attrs
               ) do
            {:ok, updated_scan, confirmation} ->
              if updated_scan.repository_id != locked.repository_id do
                Repo.rollback(:target_review_mismatch)
              end

              updated =
                locked
                |> Ecto.Changeset.change(
                  status: "submitted",
                  visibility: "public",
                  linked_review_id: updated_scan.id,
                  submitted_at: DateTime.utc_now(),
                  claim_expires_at: nil
                )
                |> Repo.update!()

              record_audit(fresh_scope, :review_task_submitted, updated, locked.status)

              {preload_task(updated), updated_scan, confirmation, fresh_scope.account}

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, {task, scan, confirmation, actor}} ->
          broadcast(task.repository_id, {:review_task_submitted, task.id})
          Scans.broadcast_verdict_recorded(scan, confirmation, actor)
          {:ok, task}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepare_verdict_attrs(attrs) do
    verdict =
      attrs
      |> Map.get("verdict", "")
      |> to_string()
      |> String.downcase()
      |> String.trim()

    provenance =
      attrs
      |> Map.get("provenance", "human")
      |> to_string()
      |> String.downcase()
      |> String.trim()

    notes =
      attrs
      |> Map.get("notes")
      |> case do
        nil -> Map.get(attrs, "summary")
        n -> n
      end
      |> to_string()
      |> String.trim()

    evidence =
      attrs
      |> Map.get("evidence", "")
      |> to_string()
      |> String.trim()

    cond do
      verdict not in ["confirmed", "disputed"] ->
        {:error, :verdict_required}

      String.length(notes) < 20 ->
        {:error, :verdict_notes_required}

      true ->
        {:ok,
         %{
           provenance: provenance,
           confirmation_attrs: %{
             "verdict" => verdict,
             "provenance" => provenance,
             "notes" => notes,
             "evidence" => if(evidence == "", do: nil, else: evidence)
           }
         }}
    end
  end

  defp submit_task_legacy_prose(task, scope, account, attrs) do
    contribution_changeset = Contribution.changeset(%Contribution{}, attrs)

    with {:ok, contribution_changeset} <- valid_changeset(contribution_changeset) do
      transition(
        task,
        scope,
        :review_task_submitted,
        :submit_contribution,
        fn locked, _fresh_scope ->
          assert_active_claimant!(locked, account)

          if not contribution_satisfies_capability?(
               locked.capability,
               Ecto.Changeset.get_field(contribution_changeset, :provenance)
             ) do
            Repo.rollback(:capability_mismatch)
          end

          version = next_contribution_version(locked.id)

          contribution =
            contribution_changeset
            |> Ecto.Changeset.put_change(:review_task_id, locked.id)
            |> Ecto.Changeset.put_change(:account_id, account.id)
            |> Ecto.Changeset.put_change(:version, version)
            |> Repo.insert!()

          locked
          |> Ecto.Changeset.change(
            status: "submitted",
            visibility: "public",
            submitted_at: DateTime.utc_now(),
            claim_expires_at: nil,
            latest_contribution_id: contribution.id
          )
          |> Repo.update!()
        end
      )
    end
  end

  defp submit_task_with_review(task, scope, account, attrs) do
    repository = task.repository || Repo.get!(Repository, task.repository_id)

    with :ok <- authorize(scope, :submit_review, repository),
         :ok <- Scans.enforce_submission_budget(scope, repository),
         {:ok, prepared} <- prepare_review_submission(task, repository, account, attrs) do
      result =
        Repo.transaction(fn ->
          locked_repository = lock_repository!(repository.id)
          fresh_scope = lock_scope_account(scope)
          locked = locked_task!(task.id)

          if locked.repository_id != locked_repository.id, do: Repo.rollback(:invalid_state)

          locked = %{locked | repository: locked_repository}
          authorize_locked!(fresh_scope, :submit_contribution, locked)

          case Policy.authorize(fresh_scope, :submit_review, locked_repository) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          assert_active_claimant!(locked, fresh_scope.account)

          if not contribution_satisfies_capability?(locked.capability, prepared.provenance) do
            Repo.rollback(:capability_mismatch)
          end

          case Scans.enforce_submission_budget_under_lock(Repo, fresh_scope.account) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          attempt = Scans.count_reviews_for_request(locked.id) + 1

          prompt_version =
            attempt_prompt_version(prepared.client_prompt_version, locked.id, attempt)

          insert_attrs =
            prepared.scan_attrs
            |> Map.put("repository_id", locked.repository_id)
            |> Map.put("submitted_by_id", fresh_scope.account.id)
            |> Map.put("commit_sha", locked.commit_sha)
            |> Map.put("commit_committed_at", locked.commit_committed_at)
            |> Map.put("source_request_id", locked.id)
            |> Map.put("prompt_version", prompt_version)
            |> Map.put("run_id", "request-#{locked.id}-attempt-#{attempt}")
            |> Map.put("visibility", "public")

          review =
            case Scans.stage_review_insert(insert_attrs) do
              {:ok, review} ->
                if review.repository_id != locked.repository_id do
                  Repo.rollback(:invalid_state)
                end

                review

              {:error, %Ecto.Changeset{} = changeset} ->
                Repo.rollback(changeset)
            end

          %Stake{}
          |> Stake.changeset(%{
            scan_id: review.id,
            account_id: fresh_scope.account.id,
            amount: Tarakan.Reputation.default_stake()
          })
          |> Repo.insert!()

          fresh_scope
          |> Audit.event_changeset(:review_submitted, review, %{
            from_state: nil,
            to_state: "#{review.review_status}:#{review.visibility}",
            metadata: %{source_request_id: locked.id}
          })
          |> Repo.insert!()

          case Scans.recalculate_repository_metrics(locked.repository_id) do
            {:ok, _repo} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          updated =
            locked
            |> Ecto.Changeset.change(
              status: "submitted",
              visibility: "public",
              linked_review_id: review.id,
              submitted_at: DateTime.utc_now(),
              claim_expires_at: nil
            )
            |> Repo.update!()

          record_audit(fresh_scope, :review_task_submitted, updated, locked.status)

          {preload_task(updated), review}
        end)

      case result do
        {:ok, {task, review}} ->
          broadcast(task.repository_id, {:review_task_submitted, task.id})
          Scans.broadcast_review_submitted(review)
          {:ok, task}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepare_review_submission(task, repository, _account, attrs) do
    with {:ok, findings_json} <- encode_document(attrs),
         {:ok, _findings} <- Tarakan.Scans.ScanFormat.parse(findings_json),
         {:ok, commit} <- Scans.verify_commit_sha(repository, task.commit_sha) do
      provenance = attrs |> Map.get("provenance", "agent") |> to_string()
      review_kind = task.kind

      if review_kind not in @finding_kinds do
        {:error, :document_not_allowed}
      else
        client_prompt = Map.get(attrs, "prompt_version") || "review"

        scan_attrs = %{
          "commit_sha" => task.commit_sha,
          "provenance" => provenance,
          "review_kind" => review_kind,
          "model" => Map.get(attrs, "model"),
          "prompt_version" => client_prompt,
          "notes" => Map.get(attrs, "summary") || Map.get(attrs, "notes"),
          "findings_json" => findings_json,
          "commit_committed_at" =>
            task.commit_committed_at || normalize_commit_precision(commit.committed_at)
        }

        trial = Scan.submission_changeset(%Scan{}, scan_attrs)

        if trial.valid? do
          {:ok,
           %{
             scan_attrs: scan_attrs,
             provenance: provenance,
             client_prompt_version: client_prompt
           }}
        else
          {:error, %{trial | action: :insert}}
        end
      end
    end
  end

  defp accept_linked_review_allowed?(%ReviewTask{linked_review_id: nil}), do: true

  defp accept_linked_review_allowed?(%ReviewTask{linked_review_id: review_id}) do
    case Repo.get(Scan, review_id) do
      %Scan{visibility: "restricted"} -> false
      %Scan{} -> true
      nil -> false
    end
  end

  defp encode_document(attrs) do
    case Map.get(attrs, "document") do
      doc when is_map(doc) ->
        case Jason.encode(doc) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, :invalid_document}
        end

      doc when is_binary(doc) ->
        trimmed = String.trim(doc)

        case Jason.decode(trimmed) do
          {:ok, _} -> {:ok, trimmed}
          {:error, _} -> {:error, :invalid_document}
        end

      _other ->
        {:error, :document_required}
    end
  end

  defp attempt_prompt_version(client, request_id, n) do
    suffix = "#req#{request_id}v#{n}"
    prefix_max = max(100 - String.length(suffix), 0)

    client =
      client
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "review"
        other -> other
      end
      |> String.slice(0, prefix_max)

    client <> suffix
  end

  defp normalize_commit_precision(nil), do: nil
  defp normalize_commit_precision(%DateTime{} = dt), do: DateTime.add(dt, 0, :microsecond)

  defp ensure_target_review_on_repository(changeset, %Repository{id: repository_id}) do
    case Ecto.Changeset.get_field(changeset, :target_review_id) do
      nil ->
        :ok

      target_id ->
        case Repo.get(Scan, target_id) do
          %Scan{repository_id: ^repository_id} -> :ok
          %Scan{} -> {:error, :target_review_mismatch}
          nil -> {:error, :target_review_missing}
        end
    end
  end

  defp assert_active_claimant!(locked, %Account{id: account_id}) do
    cond do
      locked.status != "claimed" or locked.claimed_by_id != account_id ->
        Repo.rollback(:not_claimant)

      not ReviewTask.claim_active?(locked) ->
        Repo.rollback(:claim_expired)

      true ->
        :ok
    end
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  # Backward-compatible endpoint semantics: completion now means submission.
  def complete_task(%ReviewTask{} = task, actor, attrs), do: submit_task(task, actor, attrs)

  def accept_task(%ReviewTask{} = task, actor, attrs),
    do: review_task(task, actor, "accept", "accepted", attrs)

  def request_changes(%ReviewTask{} = task, actor, attrs),
    do: review_task(task, actor, "request_changes", "changes_requested", attrs)

  def reject_task(%ReviewTask{} = task, actor, attrs),
    do: review_task(task, actor, "reject", "rejected", attrs)

  @doc "Discloses an accepted result after a separate attributable decision."
  def disclose_task(%ReviewTask{} = task, %Account{} = account, visibility, attrs) do
    disclose_task(task, Scope.for_account(account), visibility, attrs)
  end

  def disclose_task(
        %ReviewTask{} = task,
        %Scope{account: %Account{} = account} = scope,
        visibility,
        attrs
      )
      when visibility in ["public_summary", "public"] and is_map(attrs) do
    with :ok <- authorize(scope, :disclose_task, task),
         :ok <- verify_disclosure_identity(task),
         {:ok, decision_changeset} <- decision_changeset("disclose", attrs) do
      transition(task, scope, :review_task_disclosed, :disclose_task, fn locked, _fresh_scope ->
        cond do
          locked.status != "accepted" ->
            Repo.rollback(:invalid_state)

          true ->
            insert_decision!(decision_changeset, locked, account)
            now = DateTime.utc_now()

            locked
            |> Ecto.Changeset.change(
              visibility: visibility,
              disclosed_at: now,
              disclosed_by_id: account.id,
              sensitive_data_reviewed_at: if(visibility == "public", do: now),
              sensitive_data_reviewed_by_id: if(visibility == "public", do: account.id)
            )
            |> Repo.update!()
        end
      end)
    end
  end

  def disclose_task(%ReviewTask{}, %Scope{}, _visibility, _attrs),
    do: {:error, :invalid_visibility}

  def disclose_task(%ReviewTask{}, _actor, _visibility, _attrs),
    do: {:error, :unauthorized}

  def cancel_task(%ReviewTask{} = task, %Account{} = account, attrs) do
    cancel_task(task, Scope.for_account(account), attrs)
  end

  def cancel_task(%ReviewTask{} = task, %Scope{account: %Account{} = account} = scope, attrs) do
    with :ok <- authorize(scope, :cancel_task, task),
         {:ok, decision_changeset} <- decision_changeset("cancel", attrs) do
      transition(task, scope, :review_task_cancelled, :cancel_task, fn locked, _fresh_scope ->
        cond do
          ReviewTask.terminal?(locked) ->
            Repo.rollback(:closed)

          locked.status in ["claimed", "submitted"] ->
            Repo.rollback(:active_work)

          true ->
            insert_decision!(decision_changeset, locked, account)

            locked
            |> Ecto.Changeset.change(
              status: "cancelled",
              reviewed_at: DateTime.utc_now(),
              reviewed_by_id: account.id,
              claimed_at: nil,
              claim_expires_at: nil
            )
            |> Repo.update!()
        end
      end)
    end
  end

  def cancel_task(%ReviewTask{}, _actor, _attrs), do: {:error, :unauthorized}

  @doc "Immediately removes a task and its contribution from public view after moderation."
  def quarantine_task(%ReviewTask{} = task, %Scope{} = scope, reason)
      when is_binary(reason) do
    with :ok <- authorize(scope, :moderate, task),
         {:ok, decision_changeset} <- decision_changeset("cancel", %{"reason" => reason}) do
      transition(
        task,
        scope,
        :review_task_quarantined,
        :moderate,
        fn locked, fresh_scope ->
          if locked.status == "cancelled" do
            locked
          else
            insert_decision!(decision_changeset, locked, fresh_scope.account)

            locked
            |> Ecto.Changeset.change(
              status: "cancelled",
              visibility: "restricted",
              reviewed_at: DateTime.utc_now(),
              reviewed_by_id: fresh_scope.account_id,
              claimed_at: nil,
              claim_expires_at: nil,
              completed_at: nil
            )
            |> Repo.update!()
          end
        end
      )
    end
  end

  def quarantine_task(%ReviewTask{}, _actor, _reason), do: {:error, :unauthorized}

  defp review_task(task, %Account{} = account, action, status, attrs) do
    review_task(task, Scope.for_account(account), action, status, attrs)
  end

  defp review_task(
         %ReviewTask{} = task,
         %Scope{account: %Account{} = account} = scope,
         action,
         status,
         attrs
       ) do
    with :ok <- authorize(scope, :review_contribution, task),
         {:ok, decision_changeset} <- decision_changeset(action, attrs) do
      transition(
        task,
        scope,
        event_for_review(status),
        :review_contribution,
        fn locked, _fresh_scope ->
          cond do
            locked.status != "submitted" ->
              Repo.rollback(:invalid_state)

            locked.created_by_id == account.id or locked.claimed_by_id == account.id or
                contribution_by?(locked, account.id) ->
              Repo.rollback(:not_independent)

            status == "accepted" and not accept_linked_review_allowed?(locked) ->
              Repo.rollback(:linked_review_restricted)

            true ->
              insert_decision!(decision_changeset, locked, account)
              now = DateTime.utc_now()

              locked
              |> Ecto.Changeset.change(
                status: status,
                visibility: "public",
                reviewed_at: now,
                reviewed_by_id: account.id,
                completed_at: if(status == "accepted", do: now),
                claimed_at: if(status == "changes_requested", do: nil, else: locked.claimed_at),
                claim_expires_at: nil
              )
              |> Repo.update!()
          end
        end
      )
    end
  end

  defp review_task(%ReviewTask{}, _actor, _action, _status, _attrs),
    do: {:error, :unauthorized}

  defp transition(task, scope, event, policy_action, fun) do
    result =
      Repo.transaction(fn ->
        repository_id = task_repository_id!(task.id)
        repository = lock_repository!(repository_id)
        fresh_scope = lock_scope_account(scope)
        locked = locked_task!(task.id)

        if locked.repository_id != repository.id, do: Repo.rollback(:invalid_state)

        locked = %{locked | repository: repository}
        authorize_locked!(fresh_scope, policy_action, locked)

        case fun.(locked, fresh_scope) do
          {:noop, unchanged} ->
            {:noop, preload_task(unchanged)}

          %ReviewTask{} = updated ->
            record_audit(fresh_scope, event, updated, locked.status)
            updated = preload_task(updated)

            {:updated, updated,
             %{repository_promoted?: repository_promoted?(repository, updated.repository)}}
        end
      end)

    broadcast_result(result, event)
  end

  defp locked_task!(id) do
    Repo.one!(from task in ReviewTask, where: task.id == ^id, lock: "FOR UPDATE")
  end

  defp task_repository_id!(task_id) do
    Repo.one!(from task in ReviewTask, where: task.id == ^task_id, select: task.repository_id)
  end

  defp lock_repository!(repository_id) do
    Repo.one!(
      from repository in Repository,
        where: repository.id == ^repository_id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_scope_account(%Scope{account_id: account_id} = scope) do
    account =
      Repo.one!(from account in Account, where: account.id == ^account_id, lock: "FOR UPDATE")

    case Accounts.refresh_scope_for_account(account, scope) do
      {:ok, fresh_scope} -> fresh_scope
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_locked!(_scope, nil, _task), do: :ok

  defp authorize_locked!(scope, action, task) do
    case authorize(scope, action, task) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Visibility is the only content gate; task status is workflow, not
  # disclosure. A moderation-quarantined repository pulls its whole queue.
  defp visible_to(query, nil, %Repository{listing_status: status})
       when status != "quarantined" do
    where(query, [task], task.visibility in ["public_summary", "public"])
  end

  defp visible_to(query, nil, _repository), do: where(query, [task], false)

  defp visible_to(query, %Scope{account: %Account{id: account_id}} = scope, repository) do
    if Scope.token_scope?(scope, "tasks:read") do
      if authorized?(scope, :view_restricted_task, repository) do
        query
      else
        contributed_task_ids =
          from contribution in Contribution,
            where: contribution.account_id == ^account_id,
            select: contribution.review_task_id

        publicly_visible? = repository.listing_status != "quarantined"

        where(
          query,
          [task],
          (^publicly_visible? and task.visibility in ["public_summary", "public"]) or
            task.created_by_id == ^account_id or
            task.claimed_by_id == ^account_id or task.reviewed_by_id == ^account_id or
            task.id in subquery(contributed_task_ids)
        )
      end
    else
      visible_to(query, nil, repository)
    end
  end

  defp visible_to(query, _scope, _repository), do: visible_to(query, nil, nil)

  defp visible_to_scope?(%ReviewTask{} = task, nil), do: publicly_listed?(task)

  defp visible_to_scope?(%ReviewTask{} = task, %Scope{account: %Account{id: account_id}} = scope) do
    publicly_listed?(task) or
      (Scope.token_scope?(scope, "tasks:read") and
         (task.created_by_id == account_id or task.claimed_by_id == account_id or
            task.reviewed_by_id == account_id or
            Enum.any?(task.contributions, &(&1.account_id == account_id)) or
            authorized?(scope, :view_restricted_task, task)))
  end

  defp visible_to_scope?(_task, _scope), do: false

  defp publicly_listed?(%ReviewTask{repository: %Repository{listing_status: status}} = task)
       when status != "quarantined",
       do: ReviewTask.public?(task)

  defp publicly_listed?(_task), do: false

  defp expose_task(%ReviewTask{} = task, scope) do
    if full_task_access?(task, scope) do
      task
    else
      public_task(task)
    end
  end

  defp full_task_access?(
         %ReviewTask{} = task,
         %Scope{account: %Account{id: account_id}} = scope
       ) do
    Scope.token_scope?(scope, "tasks:read") and
      (task.created_by_id == account_id or task.claimed_by_id == account_id or
         task.reviewed_by_id == account_id or
         Enum.any?(task.contributions, &(&1.account_id == account_id)) or
         authorized?(scope, :view_restricted_task, task))
  end

  defp full_task_access?(_task, _scope), do: false

  # Contribution exposure follows the task's visibility alone: full public
  # tasks carry their evidence, summaries strip it, restricted tasks carry
  # nothing. Decision records stay private to authorized participants.
  defp public_task(%ReviewTask{visibility: visibility, contribution: contribution} = task) do
    public_contribution =
      case {visibility, contribution} do
        {"public", contribution} when not is_nil(contribution) ->
          contribution

        {"public_summary", contribution} when not is_nil(contribution) ->
          %{contribution | evidence: nil}

        _other ->
          nil
      end

    %{
      task
      | contribution: public_contribution,
        contributions: List.wrap(public_contribution),
        decisions: []
    }
  end

  defp active_claim_count(account_id) do
    now = DateTime.utc_now()

    Repo.aggregate(
      from(task in ReviewTask,
        where:
          task.claimed_by_id == ^account_id and
            ((task.status == "claimed" and task.claim_expires_at > ^now) or
               task.status == "submitted")
      ),
      :count
    )
  end

  defp enforce_proposal_quota!(%Scope{account: %Account{platform_role: role}})
       when role in ["moderator", "admin"],
       do: :ok

  defp enforce_proposal_quota!(%Scope{account: %Account{} = account}) do
    count = proposal_count(account.id)
    limit = proposal_limit(account)

    if count >= limit, do: Repo.rollback(:proposal_limit), else: :ok
  end

  defp proposal_quota_precheck(%Scope{account: %Account{platform_role: role}})
       when role in ["moderator", "admin"],
       do: :ok

  defp proposal_quota_precheck(%Scope{account: %Account{} = account}) do
    if proposal_count(account.id) >= proposal_limit(account),
      do: {:error, :proposal_limit},
      else: :ok
  end

  defp proposal_preflight(%Scope{account_id: account_id}, %Repository{id: repository_id}) do
    with :ok <- rate_check({:task_proposal, account_id}, 10, 60, :proposal_rate_limited),
         :ok <-
           rate_check(
             {:task_proposal_repository, account_id, repository_id},
             6,
             60,
             :proposal_rate_limited
           ) do
      :ok
    end
  end

  defp proposal_count(account_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

    Repo.aggregate(
      from(task in ReviewTask,
        where: task.created_by_id == ^account_id and task.inserted_at >= ^cutoff
      ),
      :count
    )
  end

  defp proposal_limit(%Account{trust_tier: "reviewer"}), do: 30
  defp proposal_limit(%Account{state: "active"}), do: 15
  defp proposal_limit(%Account{}), do: 3

  defp claim_mutation_preflight(%Scope{account_id: account_id}) do
    rate_check(
      {:task_claim_mutation, account_id},
      @claim_mutation_limit,
      @claim_mutation_window_seconds,
      :claim_rate_limited
    )
  end

  defp rate_check(key, limit, window_seconds, error) do
    case Tarakan.RateLimiter.check(key, limit, window_seconds) do
      :ok -> :ok
      {:error, _reason, _retry_after} -> {:error, error}
    end
  end

  defp claim_limit(%Account{state: "probation"}), do: 1
  defp claim_limit(%Account{}), do: 3

  defp claimable_now?(%ReviewTask{status: "claimed"} = task),
    do: not ReviewTask.claim_active?(task)

  defp claimable_now?(%ReviewTask{} = task), do: ReviewTask.claimable?(task)

  defp release_status(%ReviewTask{latest_contribution_id: nil}), do: "open"
  defp release_status(%ReviewTask{}), do: "changes_requested"

  defp next_contribution_version(task_id) do
    (Repo.one(
       from contribution in Contribution,
         where: contribution.review_task_id == ^task_id,
         select: max(contribution.version)
     ) || 0) + 1
  end

  defp contribution_by?(%ReviewTask{latest_contribution_id: nil}, _account_id), do: false

  defp contribution_by?(%ReviewTask{id: task_id}, account_id) do
    Repo.exists?(
      from contribution in Contribution,
        where: contribution.review_task_id == ^task_id and contribution.account_id == ^account_id
    )
  end

  defp decision_changeset(action, attrs) do
    attrs = attrs |> stringify_keys() |> Map.put("action", action)
    %ReviewDecision{} |> ReviewDecision.changeset(attrs) |> valid_changeset()
  end

  defp insert_decision!(changeset, task, account) do
    changeset
    |> Ecto.Changeset.put_change(:review_task_id, task.id)
    |> Ecto.Changeset.put_change(:account_id, account.id)
    |> Repo.insert!()
  end

  defp event_for_review("accepted"), do: :review_task_accepted
  defp event_for_review("changes_requested"), do: :review_task_changes_requested
  defp event_for_review("rejected"), do: :review_task_rejected

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_active_only(query, true) do
    where(
      query,
      [task],
      task.status in ["proposed", "open", "claimed", "submitted", "changes_requested"]
    )
  end

  defp maybe_active_only(query, false), do: query

  defp valid_changeset(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}

  defp valid_changeset(%Ecto.Changeset{} = changeset),
    do: {:error, %{changeset | action: :insert}}

  defp verify_commit(repository, changeset) do
    sha = Ecto.Changeset.get_field(changeset, :commit_sha)

    if Repository.hosted?(repository) do
      verify_hosted_commit(repository, sha)
    else
      verify_github_commit(repository, sha)
    end
  end

  # Tarakan-hosted repos are the source of truth locally - never call GitHub.
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

  defp verify_disclosure_identity(%ReviewTask{repository_id: repository_id}) do
    case Repo.get(Repository, repository_id) do
      %Repository{} = repository ->
        if Repository.hosted?(repository) do
          if Tarakan.HostedRepositories.Storage.exists?(repository),
            do: :ok,
            else: {:error, :not_found}
        else
          case GitHub.verify_public_identity(repository) do
            {:ok, _metadata} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp normalize_precision(nil), do: nil
  defp normalize_precision(%DateTime{} = datetime), do: DateTime.add(datetime, 0, :microsecond)

  defp contribution_satisfies_capability?("human", provenance),
    do: provenance in ["human", "hybrid"]

  defp contribution_satisfies_capability?("agent", provenance),
    do: provenance in ["agent", "hybrid"]

  defp contribution_satisfies_capability?("hybrid", provenance), do: provenance == "hybrid"

  defp preload_task(task_or_tasks) do
    Repo.preload(
      task_or_tasks,
      [
        :repository,
        :created_by,
        :claimed_by,
        :reviewed_by,
        :disclosed_by,
        :sensitive_data_reviewed_by,
        contribution: :account,
        contributions: :account,
        decisions: :account,
        linked_review: [:findings, :submitted_by],
        target_review: [:findings, :submitted_by]
      ],
      force: true
    )
  end

  defp authorize(scope, action, resource) do
    case Policy.authorize(scope, action, resource) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp authorized?(scope, action, resource) do
    match?(:ok, authorize(scope, action, resource))
  end

  defp promote_pending_repository!(%Repository{listing_status: "pending"} = repository, scope) do
    promoted =
      repository
      |> Repository.listing_changeset(%{listing_status: "listed"})
      |> Repo.update!()

    case Audit.record(scope, :repository_listing_status_updated, promoted, %{
           from_state: "pending",
           to_state: "listed",
           metadata: %{reason: "independent_review_task_publication"}
         }) do
      {:ok, _event} -> promoted
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  defp promote_pending_repository!(%Repository{} = repository, _scope), do: repository

  defp repository_promoted?(%Repository{listing_status: "pending"}, %Repository{
         listing_status: "listed"
       }),
       do: true

  defp repository_promoted?(_before, _after), do: false

  defp record_audit(scope, event, task, from_state) do
    case Audit.record(scope, event, task, %{
           from_state: from_state,
           to_state: task.status,
           metadata: %{status: task.status, visibility: task.visibility}
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  defp broadcast_result({:ok, {:updated, task, metadata}}, event) do
    broadcast(task.repository_id, {event, task.id})

    if metadata.repository_promoted? do
      Repositories.broadcast_registration(task.repository)
      Activity.broadcast_registration(task.repository)
    end

    {:ok, task}
  end

  defp broadcast_result({:ok, {:noop, task}}, _event), do: {:ok, task}

  defp broadcast_result({:error, reason}, _event), do: {:error, reason}

  defp topic(repository_id), do: "review_tasks:#{repository_id}"

  defp broadcast(repository_id, message) do
    Phoenix.PubSub.broadcast(Tarakan.PubSub, topic(repository_id), message)
  end
end
