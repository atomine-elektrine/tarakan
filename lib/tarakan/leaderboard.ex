defmodule Tarakan.Leaderboard do
  @moduledoc """
  Ranks contributors for the public leaderboard.

  Reputation is computed on read (`Tarakan.Reputation.score/1`), which is too
  expensive to run for every account. The leaderboard instead picks a
  candidate pool with a few batch queries — the contributors with the most
  verified work, the dominant reputation term — then computes the exact score
  and stats only for that pool. Because the vote and stake terms are bounded
  and small by design, a contributor can't crack the top on votes alone, so a
  verification-led shortlist doesn't miss anyone who belongs.

  At larger scale this should become a materialized ranking refreshed on
  contribution events; the batch approach keeps it correct and cheap for now.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.Account
  alias Tarakan.Profiles
  alias Tarakan.Repo
  alias Tarakan.Reputation
  alias Tarakan.Scans.{CanonicalFinding, Finding, FindingCheck, Scan}

  @candidate_pool 60
  @sorts ~w(reputation reviews findings verdicts)a

  # Mirror Tarakan.Reputation's verification weights for candidate shortlisting
  # only; the displayed score is the exact `Reputation.score/1`.
  @confirmed_finding 30
  @correct_verdict 15

  def sorts, do: @sorts

  @doc """
  Returns the ranked leaderboard entries — `%{account, reputation, stats}` —
  sorted by `sort` (`:reputation`, `:reviews`, `:findings`, or `:verdicts`).
  """
  def top(sort \\ :reputation, limit \\ 25) when sort in @sorts do
    ids = candidate_ids()

    entries =
      Account
      |> where([a], a.id in ^ids)
      |> Repo.all()
      |> Enum.map(fn account ->
        %{
          account: account,
          reputation: Reputation.score(account),
          stats: Profiles.contribution_stats(account)
        }
      end)
      |> Enum.filter(&(&1.reputation.total > 0))
      |> Enum.sort_by(&sort_key(&1, sort), :desc)
      |> Enum.take(limit)

    entries
  end

  defp sort_key(entry, :reputation), do: {entry.reputation.total, entry.stats.findings}
  defp sort_key(entry, :reviews), do: {entry.stats.reviews, entry.reputation.total}
  defp sort_key(entry, :findings), do: {entry.stats.findings, entry.reputation.total}
  defp sort_key(entry, :verdicts), do: {entry.stats.verdicts, entry.reputation.total}

  # Shortlist by a batch estimate of the verification term.
  defp candidate_ids do
    %{}
    |> merge_points(confirmed_findings_by_account(), @confirmed_finding)
    |> merge_points(correct_verdicts_by_account(), @correct_verdict)
    |> Enum.sort_by(fn {_id, points} -> points end, :desc)
    |> Enum.take(@candidate_pool)
    |> Enum.map(&elem(&1, 0))
  end

  defp merge_points(acc, rows, weight) do
    Enum.reduce(rows, acc, fn {account_id, count}, map ->
      Map.update(map, account_id, count * weight, &(&1 + count * weight))
    end)
  end

  defp confirmed_findings_by_account do
    CanonicalFinding
    |> join(:inner, [canonical], occurrence in Finding,
      on: occurrence.canonical_finding_id == canonical.id
    )
    |> join(:inner, [_canonical, occurrence], scan in Scan, on: scan.id == occurrence.scan_id)
    |> join(:inner, [canonical], repository in assoc(canonical, :repository))
    |> where(
      [canonical, _occurrence, scan, repository],
      scan.visibility == "public" and repository.listing_status == "listed" and
        canonical.status == "verified"
    )
    |> group_by([_canonical, _occurrence, scan], scan.submitted_by_id)
    |> select(
      [canonical, _occurrence, scan],
      {scan.submitted_by_id, count(canonical.id, :distinct)}
    )
    |> Repo.all()
  end

  defp correct_verdicts_by_account do
    FindingCheck
    |> join(:inner, [check], canonical in assoc(check, :canonical_finding))
    |> join(:inner, [_check, canonical], occurrence in assoc(canonical, :occurrences))
    |> join(:inner, [_check, _canonical, occurrence], scan in assoc(occurrence, :scan))
    |> join(:inner, [_check, canonical], repository in assoc(canonical, :repository))
    |> where(
      [check, canonical, _occurrence, scan, repository],
      scan.visibility == "public" and repository.listing_status == "listed" and
        ((check.verdict == "confirmed" and canonical.status == "verified") or
           (check.verdict == "disputed" and canonical.status == "disputed") or
           (check.verdict == "fixed" and canonical.status == "fixed"))
    )
    |> group_by([check], check.account_id)
    |> select([check], {check.account_id, count(check.canonical_finding_id, :distinct)})
    |> Repo.all()
  end
end
