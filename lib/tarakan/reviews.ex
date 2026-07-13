defmodule Tarakan.Reviews do
  @moduledoc """
  Canonical product language for the public security **Review** record.

  Reviews are today's Scans: commit-pinned findings + independent confirmations.
  This module is a façade over `Tarakan.Scans` so call sites can migrate without
  a physical table rename.
  """

  alias Tarakan.Scans

  defdelegate subscribe(repository_id), to: Scans
  defdelegate broadcast_refresh(scan), to: Scans
  defdelegate severities(), to: Scans
  defdelegate provenances(), to: Scans
  defdelegate review_kinds(), to: Scans
  defdelegate review_statuses(), to: Scans
  defdelegate visibilities(), to: Scans
  defdelegate verification_threshold(), to: Scans
  defdelegate list_indexable_findings(), to: Scans
  defdelegate get_scan(scope, id), to: Scans
  defdelegate get_finding(scope, ref), to: Scans
  defdelegate can_record_verdict?(scope, scan), to: Scans
  defdelegate accept_scan(scope, scan, attrs), to: Scans
  defdelegate reject_scan(scope, scan, attrs), to: Scans
  defdelegate contest_scan(scope, scan, attrs), to: Scans
  defdelegate update_visibility(scope, scan, visibility, attrs), to: Scans
  defdelegate enforce_submission_budget(scope, repository), to: Scans
  defdelegate enforce_submission_budget_under_lock(repo, account), to: Scans
  defdelegate stage_review_insert(attrs), to: Scans
  defdelegate count_reviews_for_request(request_id), to: Scans
  defdelegate recalculate_repository_metrics(repository_id), to: Scans
  defdelegate broadcast_review_submitted(scan), to: Scans
  defdelegate verify_commit_sha(repository, sha), to: Scans
  defdelegate public_contributor_count(), to: Scans
  defdelegate revalidate_repository_authority(repository_id), to: Scans

  def list_scans(repository), do: Scans.list_scans(repository)
  def list_scans(scope, repository), do: Scans.list_scans(scope, repository)
  def submit_scan(a, b, c), do: Scans.submit_scan(a, b, c)
  def record_confirmation(a, b, c), do: Scans.record_confirmation(a, b, c)

  def list_reviews(repository), do: list_scans(repository)
  def list_reviews(scope, repository), do: list_scans(scope, repository)
  def get_review(scope, id), do: get_scan(scope, id)
  def submit_review(a, b, c), do: submit_scan(a, b, c)
end
