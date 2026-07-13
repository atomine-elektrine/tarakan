defmodule Tarakan.Activity do
  @moduledoc """
  The registry-wide activity wire: registrations, scans, verdicts, and
  finding discussion merged into one feed. A read model over the other
  contexts' tables; writes stay where they belong.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.Account
  alias Tarakan.Discussion.Comment
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.Reputation.Vote
  alias Tarakan.Scans.{CanonicalFinding, Confirmation, Finding, Scan}

  @topic "activity"

  @doc """
  Subscribes the caller to the activity wire.

  Subscribers receive `{:activity, entry}` maps shaped like the ones
  returned by `recent/1`.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Tarakan.PubSub, @topic)
  end

  @doc """
  The most recent `limit` wire entries across all three kinds, newest first.

  By default only accepted, quorum-verified scans (and their verdicts) make
  the wire. Pass `verified_only: false` to read the whole public record as it
  happens - every public scan and verdict on a listed repository, the same
  rule the `broadcast_*` functions apply to live events.
  """
  def recent(limit \\ 12, opts \\ []) do
    verified_only = Keyword.get(opts, :verified_only, true)
    kind = Keyword.get(opts, :kind)

    # When a single kind is requested, run only that source query — so it can
    # return a full `limit` rows of that kind (rather than being starved when the
    # merged newest-`limit` window happens to hold none) and the other three
    # queries never run.
    [
      {:registration, fn -> recent_registrations(limit) end},
      {:scan, fn -> recent_scans(limit, verified_only) end},
      {:verdict, fn -> recent_verdicts(limit, verified_only) end},
      {:comment, fn -> recent_comments(limit) end}
    ]
    |> Enum.filter(fn {source, _run} -> is_nil(kind) or source == kind end)
    |> Enum.flat_map(fn {_source, run} -> run.() end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp recent_registrations(limit) do
    Repository
    |> where([repository], repository.listing_status == "listed")
    |> order_by([repository], desc: repository.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&registration_entry/1)
  end

  defp recent_scans(limit, verified_only) do
    Scan
    |> join(:inner, [scan], repository in assoc(scan, :repository))
    |> where(
      [scan, repository],
      scan.visibility in ["public_summary", "public"] and
        repository.listing_status == "listed"
    )
    |> scan_verified_filter(verified_only)
    |> order_by([scan], desc: scan.inserted_at)
    |> limit(^limit)
    |> preload([:repository, :submitted_by])
    |> Repo.all()
    |> Enum.map(&scan_entry(&1, &1.repository, &1.submitted_by))
  end

  defp recent_verdicts(limit, verified_only) do
    Confirmation
    |> join(:inner, [confirmation], scan in assoc(confirmation, :scan))
    |> join(:inner, [_confirmation, scan], repository in assoc(scan, :repository))
    |> where(
      [_confirmation, scan, repository],
      scan.visibility in ["public_summary", "public"] and
        repository.listing_status == "listed"
    )
    |> verdict_verified_filter(verified_only)
    |> order_by([confirmation, _scan, _repository], desc: confirmation.inserted_at)
    |> limit(^limit)
    |> preload([:account, scan: :repository])
    |> Repo.all()
    |> Enum.map(&verdict_entry(&1, &1.scan, &1.scan.repository, &1.account))
  end

  defp recent_comments(limit) do
    Comment
    |> join(:inner, [comment], finding in assoc(comment, :finding))
    |> join(:inner, [_comment, finding], scan in assoc(finding, :scan))
    |> join(:inner, [comment], repository in assoc(comment, :repository))
    |> where(
      [comment, _finding, scan, repository],
      is_nil(comment.removed_at) and scan.visibility == "public" and
        repository.listing_status == "listed"
    )
    |> order_by([comment], desc: comment.inserted_at)
    |> limit(^limit)
    |> preload([:account, :repository, :finding])
    |> Repo.all()
    |> Enum.map(&comment_entry(&1, &1.finding, &1.repository, &1.account))
  end

  @doc """
  The most-upvoted public canonical findings of the trailing window: net vote
  score over the last `days`, positive scores only, listed repositories only.
  Each row carries a representative public occurrence id for linking.
  """
  def hot_findings(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 6) |> min(20) |> max(1)
    days = opts |> Keyword.get(:days, 7) |> max(1)
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    vote_scores =
      Vote
      |> where([vote], vote.subject_type == "canonical_finding")
      |> where([vote], vote.inserted_at >= ^since)
      |> group_by([vote], vote.subject_id)
      |> having([vote], sum(vote.value) > 0)
      |> select([vote], %{subject_id: vote.subject_id, score: sum(vote.value)})

    rows =
      CanonicalFinding
      |> join(:inner, [canonical], score in subquery(vote_scores),
        on: score.subject_id == canonical.id
      )
      |> join(:inner, [canonical], repository in assoc(canonical, :repository))
      |> where([_canonical, _score, repository], repository.listing_status == "listed")
      |> order_by([_canonical, score], desc: score.score)
      |> order_by([canonical], desc: canonical.id)
      |> limit(^limit)
      |> select([canonical, score, repository], {canonical, repository, score.score})
      |> Repo.all()

    occurrences = public_occurrence_ids(Enum.map(rows, fn {canonical, _, _} -> canonical.id end))

    for {canonical, repository, score} <- rows,
        occurrence_public_id = occurrences[canonical.id],
        occurrence_public_id != nil do
      %{
        id: canonical.id,
        public_id: occurrence_public_id,
        title: canonical.title,
        severity: canonical.severity,
        status: canonical.status,
        score: score,
        host: repository.host,
        owner: repository.owner,
        name: repository.name
      }
    end
  end

  # The finding page is keyed by an occurrence's public id; pick the newest
  # publicly disclosed occurrence per canonical issue.
  defp public_occurrence_ids([]), do: %{}

  defp public_occurrence_ids(canonical_ids) do
    # One newest occurrence per canonical id via DISTINCT ON, instead of pulling
    # every public occurrence row and reducing in Elixir.
    Finding
    |> join(:inner, [occurrence], scan in assoc(occurrence, :scan))
    |> where(
      [occurrence, scan],
      occurrence.canonical_finding_id in ^canonical_ids and scan.visibility == "public"
    )
    |> distinct([occurrence], occurrence.canonical_finding_id)
    |> order_by([occurrence], asc: occurrence.canonical_finding_id, desc: occurrence.id)
    |> select([occurrence], {occurrence.canonical_finding_id, occurrence.public_id})
    |> Repo.all()
    |> Map.new()
  end

  defp scan_verified_filter(query, false), do: query

  defp scan_verified_filter(query, true) do
    where(query, [scan], scan.review_status == "accepted" and not is_nil(scan.verified_at))
  end

  defp verdict_verified_filter(query, false), do: query

  defp verdict_verified_filter(query, true) do
    where(
      query,
      [_confirmation, scan],
      scan.review_status == "accepted" and not is_nil(scan.verified_at)
    )
  end

  def broadcast_registration(%Repository{listing_status: "listed"} = repository) do
    broadcast(registration_entry(repository))
  end

  def broadcast_registration(%Repository{}), do: :ok

  def broadcast_scan(
        %Scan{visibility: visibility} = scan,
        %Repository{} = repository,
        %Account{} = submitter
      )
      when visibility in ["public_summary", "public"] do
    if repository.listing_status == "listed" do
      broadcast(scan_entry(scan, repository, submitter))
    else
      :ok
    end
  end

  def broadcast_scan(%Scan{}, %Repository{}, %Account{}), do: :ok

  def broadcast_verdict(
        %Confirmation{} = confirmation,
        %Scan{visibility: visibility} = scan,
        %Repository{} = repository,
        %Account{} = account
      )
      when visibility in ["public_summary", "public"] do
    if repository.listing_status == "listed" do
      broadcast(verdict_entry(confirmation, scan, repository, account))
    else
      :ok
    end
  end

  def broadcast_verdict(%Confirmation{}, %Scan{}, %Repository{}, %Account{}), do: :ok

  @doc """
  Puts a fresh discussion comment on the wire. Expects `comment` with
  `:account` and `:repository` preloaded and the finding's scan loaded for
  the visibility check.
  """
  def broadcast_comment(%Comment{} = comment, %Finding{} = finding) do
    with %Repository{listing_status: "listed"} = repository <- comment.repository,
         %Scan{visibility: "public"} <- finding.scan,
         %Account{} = account <- comment.account do
      broadcast(comment_entry(comment, finding, repository, account))
    else
      _not_public -> :ok
    end
  end

  defp registration_entry(repository) do
    %{
      id: "reg-#{repository.id}",
      kind: :registration,
      at: repository.inserted_at,
      host: repository.host,
      owner: repository.owner,
      name: repository.name,
      language: repository.primary_language,
      stars_count: repository.stars_count
    }
  end

  defp scan_entry(scan, repository, submitter) do
    %{
      id: "scan-#{scan.id}",
      kind: :scan,
      at: scan.reviewed_at || scan.inserted_at,
      handle: submitter.handle,
      host: repository.host,
      owner: repository.owner,
      name: repository.name,
      commit_sha: scan.commit_sha,
      provenance: scan.provenance,
      review_kind: scan.review_kind,
      findings_count: scan.findings_count
    }
  end

  defp verdict_entry(confirmation, scan, repository, account) do
    %{
      id: "verdict-#{confirmation.id}",
      kind: :verdict,
      at: confirmation.inserted_at,
      handle: account.handle,
      verdict: confirmation.verdict,
      provenance: confirmation.provenance,
      host: repository.host,
      owner: repository.owner,
      name: repository.name,
      scan_verified: not is_nil(scan.verified_at)
    }
  end

  defp comment_entry(comment, finding, repository, account) do
    %{
      id: "comment-#{comment.id}",
      kind: :comment,
      at: comment.inserted_at,
      handle: account.handle,
      host: repository.host,
      owner: repository.owner,
      name: repository.name,
      finding_public_id: finding.public_id,
      finding_title: finding.title
    }
  end

  defp broadcast(entry) do
    Phoenix.PubSub.broadcast(Tarakan.PubSub, @topic, {:activity, entry})
  end
end
