defmodule Tarakan.Reports do
  @moduledoc """
  Mass-facing product language for the public security **Report**.

  A Report is a Review (scan): commit-pinned findings + independent checks.
  Jobs (requests) optionally orchestrate who produces or checks a Report.

  Prefer this module in new code and docs:

  - **Report** - what was found at a commit (findings)
  - **Check** - independent confirm/dispute of a report
  - **Job** - optional work ticket (`Tarakan.Requests`)
  """

  alias Tarakan.Accounts.Scope
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans
  alias Tarakan.Scans.Scan

  defdelegate list_reports(repository), to: Scans, as: :list_scans
  defdelegate list_reports(scope, repository), to: Scans, as: :list_scans
  defdelegate get_report(scope, id), to: Scans, as: :get_scan
  defdelegate get_finding(scope, ref), to: Scans

  @doc """
  Publishes a security Report (structured findings) for a repository.

  This is the single write path masses should think about. Under the hood it
  is `Scans.submit_scan/3`. Completing a finding-producing Job with a document
  also creates a Report via `Work.submit_task/3`.
  """
  def publish_report(%Scope{} = scope, %Repository{} = repository, attrs) do
    Scans.submit_scan(scope, repository, normalize_publish_attrs(attrs))
  end

  def publish_report(%Repository{} = repository, account, attrs) do
    Scans.submit_scan(repository, account, normalize_publish_attrs(attrs))
  end

  @doc """
  Records an independent Check (confirm/dispute) on a Report.
  """
  def check_report(%Scope{} = scope, %Scan{} = report, attrs) do
    Scans.record_confirmation(scope, report, normalize_check_attrs(attrs))
  end

  def check_report(%Scan{} = report, account, attrs) do
    Scans.record_confirmation(report, account, normalize_check_attrs(attrs))
  end

  def can_check?(%Scope{} = scope, %Scan{} = report), do: Scans.can_record_verdict?(scope, report)

  defp normalize_publish_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("review_kind", "code_review")
    |> Map.put_new("provenance", "agent")
  end

  defp normalize_check_attrs(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    notes = attrs["notes"] || attrs["summary"]

    attrs
    |> Map.put("notes", notes)
    |> Map.put_new("provenance", "human")
  end
end
