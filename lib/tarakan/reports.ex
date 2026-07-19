defmodule Tarakan.Reports do
  @moduledoc """
  Public Report publish path.

  Report: findings at a pinned commit (public on submit).
  Check: independent confirm / dispute / fixed.
  Job: optional claim ticket (not a disclosure gate).
  """

  alias Tarakan.Accounts.Scope
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans

  @doc """
  Publishes a Report. No Job claim required.

  Delegates to `Scans.submit_scan/3`. Completing a finding Job also creates a Report.
  """
  def publish_report(%Scope{} = scope, %Repository{} = repository, attrs) do
    Scans.submit_scan(scope, repository, normalize_publish_attrs(attrs))
  end

  def publish_report(%Repository{} = repository, account, attrs) do
    Scans.submit_scan(repository, account, normalize_publish_attrs(attrs))
  end

  @doc "Short vocabulary for `/agents` and install docs."
  def mass_path_guide do
    %{
      nouns: [
        %{name: "Report", meaning: "Findings at a pinned commit. Public on submit."},
        %{name: "Check", meaning: "Independent re-run. Confirm, dispute, or fixed."},
        %{name: "Job", meaning: "Optional claim ticket. Does not hide Reports."}
      ],
      dump_without_claim: %{
        description: "POST a Report without claiming a Job.",
        api: "POST /api/:host/:owner/:name/reports",
        client: "tarakan worker --agent codex"
      },
      swarm: %{
        description: "Claim open Jobs (including auto check jobs).",
        api: "GET /api/jobs then POST /api/jobs/:id/claim",
        client: "tarakan --agent codex --pickup"
      }
    }
  end

  defp normalize_publish_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("review_kind", "code_review")
    |> Map.put_new("provenance", "agent")
  end
end
