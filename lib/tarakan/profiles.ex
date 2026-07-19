defmodule Tarakan.Profiles do
  @moduledoc """
  Public contributor profiles.

  A profile is the public face of an account: its identity, its standing, and
  the contributions it has made to the record. Everything here is scoped to
  what is already public - only reviews, findings, and checks on publicly
  listed repositories with disclosed visibility count, so a profile never
  reveals a restricted submission. Finding and check totals are distinct
  canonical issues; repeated report occurrences do not inflate them.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.{Account, Identity}
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.{Finding, FindingCheck, Scan}

  @public_visibilities ~w(public_summary public)
  @default_limit 30

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
  A profile's recent public contributions - disclosed reviews and finding
  checks, newest first - as a flat activity feed.
  """
  def recent_activity(%Account{id: account_id}, limit \\ 20) do
    reviews =
      public_scans(account_id)
      |> order_by([scan], desc: scan.inserted_at)
      |> limit(^limit)
      |> preload(:repository)
      |> Repo.all()
      |> Enum.map(&review_entry/1)

    checks = list_checks(%Account{id: account_id}, limit)

    (reviews ++ checks)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Listed repositories this account registered, newest first.
  """
  def list_repositories(%Account{id: account_id}, limit \\ @default_limit) do
    listed_repositories(account_id)
    |> order_by([repository], desc: repository.inserted_at)
    |> limit(^clamp_limit(limit))
    |> Repo.all()
  end

  @doc """
  Public security reports this account submitted, newest first.
  """
  def list_reviews(%Account{id: account_id}, limit \\ @default_limit) do
    public_scans(account_id)
    |> order_by([scan], desc: scan.inserted_at)
    |> limit(^clamp_limit(limit))
    |> preload(:repository)
    |> Repo.all()
    |> Enum.map(&review_entry/1)
  end

  @doc """
  Public finding occurrences this account filed (one row per occurrence with
  a linkable public id), newest first. Distinct from the stats total, which
  counts unique canonical issues.
  """
  def list_findings(%Account{id: account_id}, limit \\ @default_limit) do
    Finding
    |> join(:inner, [finding], scan in assoc(finding, :scan))
    |> join(:inner, [_finding, scan], repository in assoc(scan, :repository))
    |> where(
      [finding, scan, repository],
      scan.submitted_by_id == ^account_id and scan.visibility == "public" and
        repository.listing_status == "listed"
    )
    |> order_by([finding], desc: finding.inserted_at)
    |> limit(^clamp_limit(limit))
    |> preload(scan: :repository)
    |> Repo.all()
    |> Enum.map(&finding_entry/1)
  end

  @doc """
  Public finding checks this account cast, newest first.
  """
  def list_checks(%Account{id: account_id}, limit \\ @default_limit) do
    limit = clamp_limit(limit)

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
    |> preload(canonical_finding: :repository, scan_finding: [])
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
    |> Enum.map(&check_entry/1)
  end

  # --- entries -----------------------------------------------------------

  defp review_entry(scan) do
    %{
      id: scan.id,
      kind: :review,
      at: scan.inserted_at,
      repository: scan.repository,
      findings_count: scan.findings_count,
      provenance: scan.provenance,
      review_kind: scan.review_kind,
      review_status: scan.review_status,
      commit_sha: scan.commit_sha,
      verified: not is_nil(scan.verified_at)
    }
  end

  defp finding_entry(finding) do
    %{
      id: finding.id,
      kind: :finding,
      at: finding.inserted_at,
      public_id: finding.public_id,
      title: finding.title,
      severity: finding.severity,
      file_path: finding.file_path,
      repository: finding.scan.repository
    }
  end

  defp check_entry(check) do
    occurrence_public_id =
      case check do
        %{scan_finding: %{public_id: public_id}} when not is_nil(public_id) -> public_id
        _no_occurrence -> nil
      end

    repository =
      case check do
        %{canonical_finding: %{repository: %Repository{} = repository}} -> repository
        _missing -> nil
      end

    title =
      case check do
        %{canonical_finding: %{title: title}} when is_binary(title) -> title
        _missing -> nil
      end

    %{
      id: check.id,
      kind: :verdict,
      at: check.inserted_at,
      repository: repository,
      verdict: check.verdict,
      provenance: check.provenance,
      title: title,
      public_id: occurrence_public_id
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

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(100)
  defp clamp_limit(_limit), do: @default_limit
end
