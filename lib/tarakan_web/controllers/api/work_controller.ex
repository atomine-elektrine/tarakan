defmodule TarakanWeb.API.WorkController do
  use TarakanWeb, :controller

  alias Tarakan.Repositories
  alias Tarakan.Work
  alias Tarakan.Work.ReviewTask

  def index(conn, %{"host" => host_slug, "owner" => owner, "name" => name}) do
    case visible_repository(host_slug, owner, name, conn.assigns.current_scope) do
      nil ->
        not_found(conn, "repository is not registered with Tarakan")

      repository ->
        tasks =
          Work.list_tasks(repository,
            limit: 100,
            scope: conn.assigns.current_scope,
            active_only: true
          )

        encoded = Enum.map(tasks, &task_json/1)
        json(conn, %{jobs: encoded})
    end
  end

  @doc """
  Global Jobs queue: open / changes_requested, plus the caller's active claims.
  """
  def queue(conn, params) do
    limit =
      case Integer.parse(to_string(params["limit"] || "50")) do
        {n, _} when n > 0 -> min(n, 100)
        _ -> 50
      end

    account_id =
      case conn.assigns.current_scope do
        %{account: %{id: id}} -> id
        _ -> nil
      end

    tasks = Work.list_open_claimable_tasks(limit: limit, account_id: account_id)
    encoded = Enum.map(tasks, &task_json/1)
    json(conn, %{jobs: encoded})
  end

  defp visible_repository(host_slug, owner, name, scope) do
    case Tarakan.Hosts.host_for_slug(host_slug) do
      {:ok, host} -> Repositories.get_visible_repository(host, owner, name, scope)
      :error -> nil
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, task} <- fetch_visible_task(id, conn.assigns.current_scope) do
      json(conn, task_json(task))
    else
      {:error, :not_found} -> not_found(conn, "job not found")
    end
  end

  def claim(conn, %{"id" => id}) do
    with {:ok, task} <- fetch_visible_task(id, conn.assigns.current_scope),
         {:ok, task} <- Work.claim_task(task, conn.assigns.current_scope) do
      json(conn, task_json(task))
    else
      error -> lifecycle_error(conn, error)
    end
  end

  def release(conn, %{"id" => id}) do
    with {:ok, task} <- fetch_visible_task(id, conn.assigns.current_scope),
         {:ok, task} <- Work.release_task(task, conn.assigns.current_scope) do
      json(conn, task_json(task))
    else
      error -> lifecycle_error(conn, error)
    end
  end

  def renew(conn, %{"id" => id}) do
    with {:ok, task} <- fetch_visible_task(id, conn.assigns.current_scope),
         {:ok, task} <- Work.renew_claim(task, conn.assigns.current_scope) do
      json(conn, task_json(task))
    else
      error -> lifecycle_error(conn, error)
    end
  end

  # Retained for client compatibility. It submits evidence for independent
  # review; no client may mark its own contribution accepted.
  # Finding-kind Requests accept `document` (Tarakan Review/Scan Format v1).
  def complete(conn, %{"id" => id} = params) do
    attrs =
      params
      |> Map.take([
        "provenance",
        "summary",
        "evidence",
        "document",
        "model",
        "prompt_version",
        "notes",
        "verdict"
      ])

    with {:ok, task} <- fetch_visible_task(id, conn.assigns.current_scope),
         {:ok, task} <- Work.submit_task(task, conn.assigns.current_scope, attrs) do
      json(conn, task_json(task))
    else
      error -> lifecycle_error(conn, error)
    end
  end

  def publish(conn, %{"id" => id} = params) do
    transition(conn, id, &Work.publish_task/3, decision_attrs(params))
  end

  def accept(conn, %{"id" => id} = params) do
    transition(conn, id, &Work.accept_task/3, decision_attrs(params))
  end

  def request_changes(conn, %{"id" => id} = params) do
    transition(conn, id, &Work.request_changes/3, decision_attrs(params))
  end

  def reject(conn, %{"id" => id} = params) do
    transition(conn, id, &Work.reject_task/3, decision_attrs(params))
  end

  def cancel(conn, %{"id" => id} = params) do
    transition(conn, id, &Work.cancel_task/3, decision_attrs(params))
  end

  defp transition(conn, id, function, attrs) do
    with {:ok, task} <- fetch_visible_task(id, conn.assigns.current_scope),
         {:ok, task} <- function.(task, conn.assigns.current_scope, attrs) do
      json(conn, task_json(task))
    else
      error -> lifecycle_error(conn, error)
    end
  end

  defp decision_attrs(params), do: Map.take(params, ["reason", "evidence"])

  defp fetch_visible_task(id, scope) do
    with {id, ""} <- Integer.parse(id),
         %ReviewTask{} = task <- Work.get_visible_task(id, scope) do
      {:ok, task}
    else
      _other -> {:error, :not_found}
    end
  end

  defp task_json(task) do
    %{
      id: task.id,
      kind: task.kind,
      capability: task.capability,
      title: task.title,
      description: task.description,
      status: task.status,
      visibility: task.visibility,
      commit_sha: task.commit_sha,
      commit_committed_at: task.commit_committed_at,
      repository: repository_json(task.repository),
      creator: account_json(task.created_by),
      claimant: account_json(task.claimed_by),
      reviewer: account_json(task.reviewed_by),
      lease: lease_json(task),
      contribution: contribution_json(task.contribution),
      contributions: Enum.map(task.contributions || [], &contribution_json/1),
      decisions: Enum.map(task.decisions || [], &decision_json/1),
      linked_review_id: task.linked_review_id,
      linked_review: linked_review_json(Map.get(task, :linked_review)),
      target_review_id: Map.get(task, :target_review_id),
      target_review: linked_review_json(Map.get(task, :target_review)),
      published_at: task.published_at,
      submitted_at: task.submitted_at,
      reviewed_at: task.reviewed_at,
      completed_at: task.completed_at,
      disclosed_at: task.disclosed_at,
      discloser: account_json(task.disclosed_by),
      sensitive_data_reviewed: not is_nil(task.sensitive_data_reviewed_at),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at,
      job_url: url(~p"/jobs/#{task.id}")
    }
  end

  defp linked_review_json(nil), do: nil

  defp linked_review_json(%Ecto.Association.NotLoaded{}), do: nil

  defp linked_review_json(review) do
    findings = Map.get(review, :findings)

    findings =
      case findings do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    %{
      id: review.id,
      review_status: review.review_status,
      visibility: review.visibility,
      findings_count: review.findings_count,
      provenance: review.provenance,
      review_kind: review.review_kind,
      model: review.model,
      prompt_version: review.prompt_version,
      commit_sha: review.commit_sha,
      source_request_id: review.source_request_id,
      findings:
        Enum.map(findings, fn finding ->
          %{
            id: finding.id,
            file: finding.file_path,
            line_start: finding.line_start,
            line_end: finding.line_end,
            severity: finding.severity,
            title: finding.title,
            description: finding.description
          }
        end)
    }
  end

  defp repository_json(repository) do
    %{
      id: repository.id,
      host: repository.host,
      owner: repository.owner,
      name: repository.name,
      canonical_url: repository.canonical_url,
      participation_mode: repository.participation_mode,
      record_url:
        TarakanWeb.Endpoint.url() <> TarakanWeb.RepositoryPaths.repository_path(repository)
    }
  end

  defp account_json(nil), do: nil

  defp account_json(account) do
    %{
      id: account.id,
      handle: account.handle
    }
  end

  defp lease_json(%ReviewTask{claimed_by: nil}), do: nil

  defp lease_json(task) do
    %{
      claimed_at: task.claimed_at,
      expires_at: task.claim_expires_at,
      active: ReviewTask.claim_active?(task)
    }
  end

  defp contribution_json(nil), do: nil

  defp contribution_json(contribution) do
    %{
      id: contribution.id,
      version: contribution.version,
      provenance: contribution.provenance,
      summary: contribution.summary,
      evidence: contribution.evidence,
      contributor: account_json(contribution.account),
      submitted_at: contribution.inserted_at
    }
  end

  defp decision_json(decision) do
    %{
      id: decision.id,
      action: decision.action,
      reason: decision.reason,
      evidence: decision.evidence,
      reviewer: account_json(decision.account),
      decided_at: decision.inserted_at
    }
  end

  defp lifecycle_error(conn, {:error, :not_found}),
    do: not_found(conn, "job not found")

  defp lifecycle_error(conn, {:error, :own_task}),
    do: forbidden(conn, "that action is not allowed on this job")

  defp lifecycle_error(conn, {:error, :not_independent}),
    do: forbidden(conn, "an independent reviewer is required")

  defp lifecycle_error(conn, {:error, reason})
       when reason in [:forbidden, :unauthorized, :account_inactive, :insufficient_trust],
       do: forbidden(conn, "this account is not authorized for that action")

  defp lifecycle_error(conn, {:error, :not_claimant}),
    do: forbidden(conn, "only the current claimant may perform that action")

  defp lifecycle_error(conn, {:error, :claim_expired}),
    do: conflict(conn, "the claim has expired; claim the task again")

  defp lifecycle_error(conn, {:error, :claim_limit}),
    do: conflict(conn, "this account has reached its active claim limit")

  defp lifecycle_error(conn, {:error, :claim_rate_limited}),
    do: too_many_requests(conn, "too many claim changes; try again shortly")

  defp lifecycle_error(conn, {:error, :already_claimed}),
    do: conflict(conn, "job has an active claim")

  defp lifecycle_error(conn, {:error, :closed}),
    do: conflict(conn, "job is closed")

  defp lifecycle_error(conn, {:error, :not_open}),
    do: conflict(conn, "job is not open for claims")

  defp lifecycle_error(conn, {:error, :invalid_state}),
    do: conflict(conn, "that transition is not valid from the task's current state")

  defp lifecycle_error(conn, {:error, :active_work}),
    do: conflict(conn, "active or submitted work must be resolved before cancellation")

  defp lifecycle_error(conn, {:error, :capability_mismatch}) do
    unprocessable(conn, %{provenance: ["does not satisfy this task's required capability"]})
  end

  defp lifecycle_error(conn, {:error, :document_required}) do
    unprocessable(conn, %{
      document: ["is required (Tarakan Review/Scan Format object with findings)"]
    })
  end

  defp lifecycle_error(conn, {:error, :document_or_prose_required}) do
    unprocessable(conn, %{
      document: ["provide a Review Format document, or summary+evidence for legacy prose"]
    })
  end

  defp lifecycle_error(conn, {:error, :document_not_allowed}) do
    unprocessable(conn, %{
      document: ["is not accepted for this request kind; use summary and evidence"]
    })
  end

  defp lifecycle_error(conn, {:error, :verdict_required}) do
    unprocessable(conn, %{
      verdict: ["is required (confirmed or disputed) with notes ≥ 20 characters"]
    })
  end

  defp lifecycle_error(conn, {:error, :verdict_notes_required}) do
    unprocessable(conn, %{
      notes: ["must be at least 20 characters (use notes or summary)"]
    })
  end

  defp lifecycle_error(conn, {:error, :target_review_required}),
    do: unprocessable(conn, %{target_review_id: ["is required for verify_findings"]})

  defp lifecycle_error(conn, {:error, :target_review_missing}),
    do: unprocessable(conn, %{target_review_id: ["does not exist"]})

  defp lifecycle_error(conn, {:error, :target_review_mismatch}),
    do: unprocessable(conn, %{target_review_id: ["must belong to the same repository"]})

  defp lifecycle_error(conn, {:error, :conflict_of_interest}),
    do: forbidden(conn, "review submitters cannot verify their own review")

  defp lifecycle_error(conn, {:error, :invalid_document}) do
    unprocessable(conn, %{document: ["must be a valid JSON Review/Scan Format object"]})
  end

  defp lifecycle_error(conn, {:error, :submission_limit}),
    do: too_many_requests(conn, "daily review submission limit reached")

  defp lifecycle_error(conn, {:error, :submission_rate_limited}),
    do: too_many_requests(conn, "too many review submissions; try again shortly")

  defp lifecycle_error(conn, {:error, :commit_not_found}),
    do: unprocessable(conn, %{commit_sha: ["is not known for this repository"]})

  defp lifecycle_error(conn, {:error, :commit_mismatch}),
    do: unprocessable(conn, %{commit_sha: ["does not match the GitHub commit"]})

  defp lifecycle_error(conn, {:error, reason})
       when reason in [:rate_limited, :unavailable, :identity_changed],
       do: service_unavailable(conn, "could not verify commit identity (#{reason})")

  defp lifecycle_error(conn, {:error, :linked_review_restricted}),
    do: conflict(conn, "linked review is restricted or missing; cannot close this request")

  defp lifecycle_error(conn, {:error, %Ecto.Changeset{} = changeset}),
    do: unprocessable(conn, changeset_errors(changeset))

  defp lifecycle_error(conn, {:error, reason}),
    do: forbidden(conn, "action denied: #{inspect(reason)}")

  defp service_unavailable(conn, message) do
    conn |> put_status(:service_unavailable) |> json(%{error: message})
  end

  defp not_found(conn, message) do
    conn |> put_status(:not_found) |> json(%{error: message})
  end

  defp forbidden(conn, message) do
    conn |> put_status(:forbidden) |> json(%{error: message})
  end

  defp conflict(conn, message) do
    conn |> put_status(:conflict) |> json(%{error: message})
  end

  defp too_many_requests(conn, message) do
    conn |> put_status(:too_many_requests) |> json(%{error: message})
  end

  defp unprocessable(conn, errors) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})
  end

  defp changeset_errors(changeset), do: TarakanWeb.ChangesetErrors.to_map(changeset)
end
