defmodule Tarakan.Profiles do
  @moduledoc """
  Public contributor profiles.

  A profile is the public face of an account: its identity, its standing, and
  the contributions it has made to the record. Everything here is scoped to
  what is already public - only reviews and verdicts on publicly listed
  repositories with disclosed visibility count, so a profile never reveals a
  restricted submission. Finding and verdict totals are distinct canonical
  issues; repeated report occurrences do not inflate them.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.{Account, Identity}
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.{Finding, FindingCheck, Scan}

  @public_visibilities ~w(public_summary public)

  @doc """
  Fetches the public profile for a handle, with linked host identities
  preloaded. Returns `nil` for an unknown handle.
  """
  def get_profile(handle) when is_binary(handle) do
    case Repo.get_by(Account, handle: String.downcase(handle)) do
      nil -> nil
      account -> Repo.preload(account, identities: from(i in Identity, order_by: i.provider))
    end
  end

  def get_profile(_handle), do: nil

  @doc """
  Contribution tallies for a profile, counting only public work: disclosed
  reviews, canonical findings, checks on canonical findings, and registered
  repositories that are publicly listed.
  """
  def contribution_stats(%Account{id: account_id}) do
    %{
      reviews: count(public_scans(account_id)),
      findings: count(public_findings(account_id)),
      verdicts: count(public_verdicts(account_id)),
      repositories: count(listed_repositories(account_id))
    }
  end

  @doc """
  A profile's recent public contributions - disclosed reviews and finding checks,
  newest first - as a flat activity feed.
  """
  def recent_activity(%Account{id: account_id}, limit \\ 20) do
    reviews =
      public_scans(account_id)
      |> order_by([scan], desc: scan.inserted_at)
      |> limit(^limit)
      |> preload(:repository)
      |> Repo.all()
      |> Enum.map(&review_entry/1)

    checks =
      FindingCheck
      |> join(:inner, [check], canonical in assoc(check, :canonical_finding))
      |> join(:inner, [_check, canonical], occurrence in assoc(canonical, :occurrences))
      |> join(:inner, [_check, _canonical, occurrence], scan in assoc(occurrence, :scan))
      |> join(:inner, [_check, canonical], repository in assoc(canonical, :repository))
      |> where(
        [check, _canonical, _occurrence, scan, repository],
        check.account_id == ^account_id and scan.visibility == "public" and
          repository.listing_status == "listed"
      )
      |> distinct([check], check.id)
      |> order_by([check], desc: check.id)
      |> limit(^limit)
      |> preload(canonical_finding: :repository)
      |> Repo.all()
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(limit)
      |> Enum.map(&check_entry/1)

    (reviews ++ checks)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # --- entries -----------------------------------------------------------

  defp review_entry(scan) do
    %{
      kind: :review,
      at: scan.inserted_at,
      repository: scan.repository,
      findings_count: scan.findings_count,
      provenance: scan.provenance,
      verified: not is_nil(scan.verified_at)
    }
  end

  defp check_entry(check) do
    %{
      kind: :verdict,
      at: check.inserted_at,
      repository: check.canonical_finding.repository,
      verdict: check.verdict,
      provenance: check.provenance
    }
  end

  # --- scoped queries ----------------------------------------------------

  defp public_scans(account_id) do
    Scan
    |> join(:inner, [scan], repository in assoc(scan, :repository))
    |> where(
      [scan, repository],
      scan.submitted_by_id == ^account_id and
        scan.visibility in @public_visibilities and
        repository.listing_status == "listed"
    )
  end

  defp public_findings(account_id) do
    Finding
    |> join(:inner, [finding], scan in assoc(finding, :scan))
    |> join(:inner, [finding, scan], repository in assoc(scan, :repository))
    |> where(
      [finding, scan, repository],
      scan.submitted_by_id == ^account_id and scan.visibility == "public" and
        repository.listing_status == "listed"
    )
    |> select([finding], finding.canonical_finding_id)
    |> distinct(true)
  end

  defp public_verdicts(account_id) do
    FindingCheck
    |> join(:inner, [check], canonical in assoc(check, :canonical_finding))
    |> join(:inner, [_check, canonical], occurrence in assoc(canonical, :occurrences))
    |> join(:inner, [_check, _canonical, occurrence], scan in assoc(occurrence, :scan))
    |> join(:inner, [_check, canonical], repository in assoc(canonical, :repository))
    |> where(
      [check, _canonical, _occurrence, scan, repository],
      check.account_id == ^account_id and scan.visibility == "public" and
        repository.listing_status == "listed"
    )
    |> select([check], check.canonical_finding_id)
    |> distinct(true)
  end

  defp listed_repositories(account_id) do
    Repository
    |> where(
      [repository],
      repository.submitted_by_id == ^account_id and repository.listing_status == "listed"
    )
  end

  defp count(query), do: Repo.aggregate(query, :count)
end
