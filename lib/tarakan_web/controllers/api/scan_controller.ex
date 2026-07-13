defmodule TarakanWeb.API.ScanController do
  use TarakanWeb, :controller

  alias Tarakan.Repositories
  alias Tarakan.Scans
  alias Tarakan.FindingMemory

  @doc """
  Records a review submitted by a contributor or external harness.

  Every submission self-reports its provenance (`agent`, `human`, or `hybrid`)
  and review kind. Agent and hybrid reviews also identify the model and prompt
  version. The document is required so a client bug cannot silently record an
  empty result. Self-reported provenance is not an identity attestation and is
  never sufficient for reputation or publication on its own.
  """
  def create(conn, %{"host" => host_slug, "owner" => owner, "name" => name} = params) do
    scope = conn.assigns.current_scope

    with {:repository, %{} = repository} <-
           {:repository, visible_repository(host_slug, owner, name, scope)},
         {:document, {:ok, findings_json}} <- {:document, encode_document(params)} do
      attrs = %{
        "commit_sha" => params["commit_sha"],
        "model" => params["model"],
        "prompt_version" => params["prompt_version"],
        "run_id" => params["run_id"],
        "provenance" => params["provenance"] || "agent",
        "review_kind" => params["review_kind"] || "code_review",
        "notes" => params["notes"],
        "findings_json" => findings_json
      }

      case Tarakan.Reports.publish_report(scope, repository, attrs) do
        {:ok, scan} ->
          conn
          |> put_status(:created)
          |> json(scan_json(scan, repository))

        {:error, :commit_not_found} ->
          unprocessable(conn, %{commit_sha: ["commit not found in this repository on GitHub"]})

        {:error, reason} when reason in [:identity_changed, :not_public, :commit_mismatch] ->
          unprocessable(conn, %{
            commit_sha: ["repository identity or commit could not be bound safely on GitHub"]
          })

        {:error, :rate_limited} ->
          upstream_unavailable(conn, "GitHub is rate limiting requests; try again shortly")

        {:error, :unavailable} ->
          upstream_unavailable(conn, "GitHub could not be reached; try again shortly")

        {:error, :unauthorized} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "this account is not authorized to submit reviews"})

        {:error, :submission_limit} ->
          conn
          |> put_resp_header("retry-after", "86400")
          |> put_status(:too_many_requests)
          |> json(%{error: "daily review submission limit reached"})

        {:error, :submission_rate_limited} ->
          conn
          |> put_resp_header("retry-after", "60")
          |> put_status(:too_many_requests)
          |> json(%{error: "review submission rate exceeded"})

        {:error, %Ecto.Changeset{} = changeset} ->
          unprocessable(conn, changeset_errors(changeset))
      end
    else
      {:repository, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "repository is not registered with Tarakan"})

      {:document, :error} ->
        unprocessable(conn, %{document: ["is required and must be a Tarakan Scan Format object"]})
    end
  end

  @doc "Returns compact, prompt-safe canonical finding memory for a repository."
  def memory(conn, %{"host" => host_slug, "owner" => owner, "name" => name} = params) do
    case visible_repository(host_slug, owner, name, conn.assigns.current_scope) do
      %{} = repository ->
        findings =
          repository
          |> FindingMemory.list_repository_memory(limit: 300)
          |> Enum.map(&memory_finding_json(&1, params["commit_sha"]))

        json(conn, %{
          repository: "#{repository.owner}/#{repository.name}",
          target_commit_sha: params["commit_sha"],
          findings: findings
        })

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "repository is not registered"})
    end
  end

  @doc "Records a confirm, dispute, or fixed verdict on one canonical finding."
  def finding_verdict(
        conn,
        %{
          "host" => host_slug,
          "owner" => owner,
          "name" => name,
          "public_id" => public_id
        } = params
      ) do
    scope = conn.assigns.current_scope

    case visible_repository(host_slug, owner, name, scope) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "repository is not registered"})

      repository ->
        attrs = %{
          "commit_sha" => params["commit_sha"],
          "verdict" => params["verdict"],
          "provenance" => params["provenance"] || "agent",
          "notes" => params["notes"],
          "evidence" => params["evidence"]
        }

        case FindingMemory.record_check(scope, repository, public_id, attrs) do
          {:ok, _check, canonical} ->
            conn |> put_status(:created) |> json(canonical_finding_json(canonical))

          {:error, :not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "canonical finding not found"})

          {:error, :commit_not_found} ->
            unprocessable(conn, %{commit_sha: ["finding was not observed at this commit"]})

          {:error, :conflict_of_interest} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "a finding submitter cannot independently verify it"})

          {:error, :unauthorized} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "this credential is not authorized to verify findings"})

          {:error, %Ecto.Changeset{} = changeset} ->
            unprocessable(conn, changeset_errors(changeset))
        end
    end
  end

  @doc """
  Lists reviews visible to the caller. A reviewer-tier credential with
  `reviews:read` sees restricted findings; other callers see only disclosed
  reviews, redacted per the platform's disclosure rules.
  """
  def index(conn, %{"host" => host_slug, "owner" => owner, "name" => name}) do
    scope = conn.assigns.current_scope

    case resolvable_repository(host_slug, owner, name) do
      %{} = repository ->
        # Repository existence is resolved here (pending repos are part of the
        # review queue); sensitive findings are gated per-scan by list_scans.
        scans = Scans.list_scans(scope, repository)
        encoded = Enum.map(scans, &scan_summary_json/1)
        # Mass key "reports" + legacy reviews/scans.
        json(conn, %{reports: encoded, reviews: encoded, scans: encoded})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "repository is not registered with Tarakan"})
    end
  end

  @doc """
  Records a verdict (and optional proof-of-concept) on a review. The caller
  must be an independent qualified reviewer and not the review's submitter.
  """
  def verdict(conn, %{"host" => host_slug, "owner" => owner, "name" => name, "id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:repository, %{} = repository} <-
           {:repository, resolvable_repository(host_slug, owner, name)},
         {:scan_id, {scan_id, ""}} <- {:scan_id, Integer.parse(id)},
         {:scan, {:ok, scan}} <- {:scan, Scans.get_scan(scope, scan_id)},
         {:owned, true} <- {:owned, scan.repository_id == repository.id} do
      attrs = %{
        "verdict" => params["verdict"],
        "provenance" => params["provenance"] || "agent",
        "notes" => params["notes"],
        "evidence" => params["evidence"]
      }

      case Scans.record_confirmation(scope, scan, attrs) do
        {:ok, _confirmation} ->
          {:ok, updated} = Scans.get_scan(scope, scan_id)
          conn |> put_status(:created) |> json(scan_summary_json(updated))

        {:error, :conflict_of_interest} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "the submitter of a review cannot verify it"})

        {:error, :unauthorized} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "this credential is not authorized to verify reviews"})

        {:error, %Ecto.Changeset{} = changeset} ->
          unprocessable(conn, changeset_errors(changeset))

        {:error, reason} ->
          upstream_unavailable(conn, "verdict could not be recorded (#{inspect(reason)})")
      end
    else
      {:repository, nil} ->
        conn |> put_status(:not_found) |> json(%{error: "repository is not registered"})

      {:scan_id, _invalid} ->
        conn |> put_status(:not_found) |> json(%{error: "review not found"})

      {:scan, {:error, :not_found}} ->
        conn |> put_status(:not_found) |> json(%{error: "review not found"})

      {:owned, false} ->
        conn |> put_status(:not_found) |> json(%{error: "review not found for this repository"})
    end
  end

  defp visible_repository(host_slug, owner, name, scope) do
    case Tarakan.Hosts.host_for_slug(host_slug) do
      {:ok, host} -> Repositories.get_visible_repository(host, owner, name, scope)
      :error -> nil
    end
  end

  # Existence-only lookup for the reviewer endpoints (findings visibility is
  # enforced per-scan, and pending repos are legitimately in the review queue).
  defp resolvable_repository(host_slug, owner, name) do
    case Tarakan.Hosts.host_for_slug(host_slug) do
      {:ok, host} -> Repositories.get_repository(host, owner, name)
      :error -> nil
    end
  end

  defp scan_summary_json(scan) do
    %{
      id: scan.id,
      commit_sha: scan.commit_sha,
      provenance: scan.provenance,
      review_kind: scan.review_kind,
      model: scan.model,
      prompt_version: scan.prompt_version,
      run_id: scan.run_id,
      review_status: scan.review_status,
      visibility: scan.visibility,
      verified: not is_nil(scan.verified_at),
      findings_count: scan.findings_count,
      details_visible: scan.details_visible,
      submitter: scan.submitted_by && scan.submitted_by.handle,
      findings: scan_findings_json(scan),
      confirmations: scan_confirmations_json(scan)
    }
  end

  defp scan_findings_json(%{details_visible: true, findings: findings}) when is_list(findings) do
    Enum.map(findings, fn finding ->
      %{
        public_id: finding.public_id,
        canonical_finding_id: finding.canonical_finding && finding.canonical_finding.public_id,
        disposition: finding.disposition,
        file: finding.file_path,
        line_start: finding.line_start,
        line_end: finding.line_end,
        severity: finding.severity,
        title: finding.title,
        description: finding.description
      }
    end)
  end

  defp scan_findings_json(_scan), do: []

  defp scan_confirmations_json(%{confirmations: confirmations}) when is_list(confirmations) do
    Enum.map(confirmations, fn confirmation ->
      %{
        verdict: confirmation.verdict,
        provenance: confirmation.provenance,
        verifier: confirmation.account && confirmation.account.handle
      }
    end)
  end

  defp scan_confirmations_json(_scan), do: []

  defp encode_document(%{"document" => document}) when is_map(document) do
    {:ok, Jason.encode!(document)}
  end

  defp encode_document(_params), do: :error

  defp scan_json(scan, repository) do
    %{
      id: scan.id,
      repository: "#{repository.owner}/#{repository.name}",
      commit_sha: scan.commit_sha,
      commit_committed_at: scan.commit_committed_at,
      model: scan.model,
      prompt_version: scan.prompt_version,
      run_id: scan.run_id,
      provenance: scan.provenance,
      provenance_attestation: "self_reported",
      review_kind: scan.review_kind,
      findings_count: scan.findings_count,
      verified: Scans.Scan.verified?(scan),
      review_status: scan.review_status,
      visibility: scan.visibility,
      record_url:
        TarakanWeb.Endpoint.url() <> TarakanWeb.RepositoryPaths.repository_path(repository)
    }
  end

  defp memory_finding_json(finding, target_commit_sha) do
    finding
    |> Map.put(:same_commit, finding.last_seen_commit_sha == target_commit_sha)
    |> Map.update!(:description, &String.slice(&1, 0, 1200))
  end

  defp canonical_finding_json(finding) do
    %{
      public_id: finding.public_id,
      status: finding.status,
      commit_sha: finding.last_seen_commit_sha,
      detections_count: finding.detections_count,
      distinct_submitters_count: finding.distinct_submitters_count,
      distinct_models_count: finding.distinct_models_count,
      confirmations_count: finding.confirmations_count,
      disputes_count: finding.disputes_count,
      verified: finding.status == "verified"
    }
  end

  defp unprocessable(conn, errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  defp upstream_unavailable(conn, message) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: message})
  end

  defp changeset_errors(changeset), do: TarakanWeb.ChangesetErrors.to_map(changeset)
end
