defmodule Tarakan.Reputation do
  @moduledoc """
  Voting and the reputation algorithm.

  Reputation blends two signals, deliberately weighted so verification always
  dominates popularity:

    * **Verification** — the record's own truth machinery. A distinct
      canonical finding independently confirmed, or a check that matched the
      settled outcome. This is the large term.

    * **Votes** — community up/down votes on your comments, weighted by the
      voter's standing and capped per item. Canonical-finding votes rank the
      shared issue and are intentionally not assigned to any one reporter.

  A wrong-but-popular finding therefore cannot out-earn a verified one, which
  is the whole point of keeping reputation honest on a security record.

  The displayed per-item score (`vote_summary/3`) is the plain net of up and
  down votes; the authority weighting applies only to the reputation total.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Discussion.Comment
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Reputation.{Stake, Vote}
  alias Tarakan.Scans.{CanonicalFinding, Finding, FindingCheck, Scan}

  # Verification weights (the dominant term).
  @confirmed_finding 30
  @correct_verdict 15

  # Reputation staked on each submitted review. Returned on verification,
  # slashed if the review is refuted (contested), and locked while it awaits
  # quorum — but only for a window, so an unreviewed submission does not hold
  # reputation hostage forever.
  @default_stake 10
  @stake_lock_days 14

  @doc "The reputation wagered on every submitted review."
  def default_stake, do: @default_stake

  # Vote weighting and bounds (the small term).
  @vote_item_cap 15
  @public_visibility "public"

  @topic "reputation"

  @doc "Subscribes to reputation/vote change broadcasts."
  def subscribe do
    Phoenix.PubSub.subscribe(Tarakan.PubSub, @topic)
  end

  @doc """
  Records `account`'s vote on a subject. Passing the value the account has
  already cast clears the vote (a toggle); any other `-1`/`+1` sets it.
  Voting on your own work is refused.
  """
  def cast_vote(%Scope{account: %Account{} = account} = scope, subject_type, subject_id, value)
      when value in [-1, 1] do
    with :ok <- authorize_vote(scope, subject_type, subject_id, account) do
      existing =
        Repo.get_by(Vote,
          account_id: account.id,
          subject_type: subject_type,
          subject_id: subject_id
        )

      result =
        cond do
          existing && existing.value == value -> Repo.delete(existing)
          existing -> existing |> Vote.changeset(%{value: value}) |> Repo.update()
          true -> vote_changeset(account, subject_type, subject_id, value) |> Repo.insert()
        end

      case result do
        {:ok, _vote} ->
          broadcast(subject_type, subject_id)
          {:ok, vote_summary(subject_type, subject_id, account.id)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def cast_vote(_scope, _type, _id, _value), do: {:error, :unauthorized}

  @doc """
  The public tally for one subject: net score, and the caller's own standing
  vote (`-1`, `0`, or `+1`).
  """
  def vote_summary(subject_type, subject_id, account_id \\ nil) do
    rows =
      Vote
      |> where([v], v.subject_type == ^subject_type and v.subject_id == ^subject_id)
      |> select([v], %{value: v.value, account_id: v.account_id})
      |> Repo.all()

    %{
      score: Enum.sum_by(rows, & &1.value),
      my_vote:
        account_id &&
          (Enum.find_value(rows, 0, fn r -> r.account_id == account_id && r.value end) || 0)
    }
  end

  @doc """
  Batch tally for many subjects of one type, as a map of
  `subject_id => %{score, my_vote}`. Used to render lists without N queries.
  """
  def vote_summaries(subject_type, subject_ids, account_id \\ nil)
  def vote_summaries(_subject_type, [], _account_id), do: %{}

  def vote_summaries(subject_type, subject_ids, account_id) do
    Vote
    |> where([v], v.subject_type == ^subject_type and v.subject_id in ^subject_ids)
    |> select([v], %{subject_id: v.subject_id, value: v.value, account_id: v.account_id})
    |> Repo.all()
    |> Enum.group_by(& &1.subject_id)
    |> Map.new(fn {subject_id, rows} ->
      {subject_id,
       %{
         score: Enum.sum_by(rows, & &1.value),
         my_vote:
           account_id &&
             (Enum.find_value(rows, 0, fn r -> r.account_id == account_id && r.value end) || 0)
       }}
    end)
  end

  @doc """
  The account's reputation: the verification term plus the bounded,
  authority-weighted vote term, floored at zero. Also returns the breakdown so
  a profile can show where the number comes from.
  """
  def score(%Account{} = account) do
    verification = verification_points(account.id)
    votes = vote_points(account.id)
    %{slashed: slashed, at_risk: at_risk} = stake_position(account.id)

    %{
      total: max(verification + votes - slashed - at_risk, 0),
      verification: verification,
      votes: votes,
      slashed: slashed,
      at_risk: at_risk
    }
  end

  @doc """
  The stake state of one review, for display: `%{amount, status}` where status
  is `:at_risk`, `:returned`, or `:slashed`, or `nil` for a review submitted
  before staking existed.
  """
  def review_stake(%Scan{} = scan) do
    case Repo.get_by(Stake, scan_id: scan.id) do
      nil ->
        nil

      %Stake{amount: amount} ->
        %{amount: amount, status: stake_status(scan)}
    end
  end

  defp stake_status(%Scan{} = scan) do
    threshold = Tarakan.Scans.verification_threshold()
    cutoff = DateTime.add(DateTime.utc_now(), -@stake_lock_days * 24 * 3600, :second)

    cond do
      not is_nil(scan.verified_at) -> :returned
      scan.disputes_count - scan.confirmations_count >= threshold -> :slashed
      DateTime.compare(scan.inserted_at, cutoff) == :gt -> :at_risk
      true -> :returned
    end
  end

  @doc "Recomputes and stores the cached `accounts.reputation` value."
  def refresh(%Account{} = account) do
    total = score(account).total

    if total != account.reputation do
      account |> Ecto.Changeset.change(reputation: total) |> Repo.update()
    else
      {:ok, account}
    end
  end

  # --- verification term -------------------------------------------------

  defp verification_points(account_id) do
    confirmed_findings =
      CanonicalFinding
      |> join(:inner, [canonical], occurrence in Finding,
        on: occurrence.canonical_finding_id == canonical.id
      )
      |> join(:inner, [_canonical, occurrence], scan in Scan, on: scan.id == occurrence.scan_id)
      |> join(
        :inner,
        [canonical, _occurrence, _scan],
        repository in assoc(canonical, :repository)
      )
      |> where(
        [canonical, _occurrence, scan, repository],
        scan.submitted_by_id == ^account_id and scan.visibility == @public_visibility and
          repository.listing_status == "listed" and canonical.status == "verified"
      )
      |> select([canonical], canonical.id)
      |> distinct(true)
      |> Repo.aggregate(:count)

    correct_verdicts =
      FindingCheck
      |> join(:inner, [check], canonical in assoc(check, :canonical_finding))
      |> join(:inner, [_check, canonical], repository in assoc(canonical, :repository))
      |> where(
        [check, canonical, repository],
        check.account_id == ^account_id and repository.listing_status == "listed" and
          ((check.verdict == "confirmed" and canonical.status == "verified") or
             (check.verdict == "disputed" and canonical.status == "disputed") or
             (check.verdict == "fixed" and canonical.status == "fixed"))
      )
      |> select([check], check.canonical_finding_id)
      |> distinct(true)
      |> Repo.aggregate(:count)

    confirmed_findings * @confirmed_finding +
      correct_verdicts * @correct_verdict
  end

  # --- stake term --------------------------------------------------------

  # A stake is only slashed when the review is AFFIRMATIVELY refuted — net
  # qualified disputes reach the same quorum verification requires. Silence
  # (an unreviewed review) is never a slash; it is returned once the lock
  # window passes, so a review cannot be griefed by simply ignoring it, and a
  # lone disputer cannot dock anyone. `confirmations_count`/`disputes_count`
  # already count only qualified reviewers' evidence-backed verdicts.
  defp stake_position(account_id) do
    threshold = Tarakan.Scans.verification_threshold()
    cutoff = DateTime.add(DateTime.utc_now(), -@stake_lock_days * 24 * 3600, :second)

    rows =
      Stake
      |> join(:inner, [stake], scan in assoc(stake, :scan))
      |> where([stake, _scan], stake.account_id == ^account_id)
      |> select([stake, scan], %{
        amount: stake.amount,
        verified: not is_nil(scan.verified_at),
        contested: scan.review_status == "contested" or scan.visibility == "restricted",
        net_disputes: scan.disputes_count - scan.confirmations_count,
        recent: scan.inserted_at > ^cutoff
      })
      |> Repo.all()

    Enum.reduce(rows, %{slashed: 0, at_risk: 0}, fn row, acc ->
      cond do
        # Returned outright: a verified review's stake comes back.
        row.verified -> acc
        # Slashed: moderation takedown / contested label, or dispute quorum.
        row.contested -> %{acc | slashed: acc.slashed + row.amount}
        row.net_disputes >= threshold -> %{acc | slashed: acc.slashed + row.amount}
        # Locked while it still might reach quorum, but only for the window.
        row.recent -> %{acc | at_risk: acc.at_risk + row.amount}
        # Otherwise returned: unreviewed past the window is not a penalty.
        true -> acc
      end
    end)
  end

  # --- vote term ---------------------------------------------------------

  defp vote_points(account_id) do
    comment_ids = authored_comment_ids(account_id)

    weighted_item_score("comment", comment_ids)
  end

  # Sums each item's authority-weighted votes, clamped to ±@vote_item_cap so a
  # single mass-voted item cannot dominate.
  defp weighted_item_score(_subject_type, []), do: 0

  defp weighted_item_score(subject_type, subject_ids) do
    Vote
    |> join(:inner, [v], voter in assoc(v, :account))
    |> where([v, _voter], v.subject_type == ^subject_type and v.subject_id in ^subject_ids)
    |> select([v, voter], %{
      subject_id: v.subject_id,
      value: v.value,
      role: voter.platform_role,
      tier: voter.trust_tier
    })
    |> Repo.all()
    |> Enum.group_by(& &1.subject_id)
    |> Enum.map(fn {_id, rows} ->
      rows
      |> Enum.sum_by(fn row -> row.value * voter_weight(row.role, row.tier) end)
      |> clamp(@vote_item_cap)
    end)
    |> Enum.sum()
  end

  defp voter_weight(role, _tier) when role in ["moderator", "admin"], do: 3
  defp voter_weight(_role, "reviewer"), do: 3
  defp voter_weight(_role, "contributor"), do: 2
  defp voter_weight(_role, _tier), do: 1

  defp clamp(value, limit), do: value |> max(-limit) |> min(limit)

  # --- authorization -----------------------------------------------------

  defp authorize_vote(scope, subject_type, subject_id, account) do
    with :ok <- allow_cast(scope),
         {:ok, author_ids} <- subject_authors(subject_type, subject_id) do
      if account.id in author_ids, do: {:error, :own_content}, else: :ok
    end
  end

  defp allow_cast(scope) do
    if Policy.allowed?(scope, :cast_vote), do: :ok, else: {:error, :unauthorized}
  end

  # A subject is votable only when it is publicly visible. Every submitter who
  # reported a canonical issue is treated as an author for self-vote checks.
  defp subject_authors("canonical_finding", canonical_finding_id) do
    query =
      CanonicalFinding
      |> join(:inner, [canonical], occurrence in assoc(canonical, :occurrences))
      |> join(:inner, [_canonical, occurrence], scan in assoc(occurrence, :scan))
      |> join(
        :inner,
        [canonical, _occurrence, _scan],
        repository in assoc(canonical, :repository)
      )
      |> where(
        [canonical, _occurrence, scan, repository],
        canonical.id == ^canonical_finding_id and scan.visibility == @public_visibility and
          repository.listing_status == "listed"
      )
      |> select([_canonical, _occurrence, scan], scan.submitted_by_id)
      |> distinct(true)

    case Repo.all(query) do
      [] -> {:error, :not_found}
      author_ids -> {:ok, author_ids}
    end
  end

  defp subject_authors("comment", comment_id) do
    case Repo.get(Comment, comment_id) do
      %Comment{removed_at: nil, account_id: account_id} -> {:ok, [account_id]}
      _removed_or_missing -> {:error, :not_found}
    end
  end

  defp subject_authors(_subject_type, _subject_id), do: {:error, :not_found}

  # --- scoped queries ----------------------------------------------------

  defp authored_comment_ids(account_id) do
    Comment
    |> where([c], c.account_id == ^account_id and is_nil(c.removed_at))
    |> select([c], c.id)
    |> Repo.all()
  end

  defp vote_changeset(account, subject_type, subject_id, value) do
    Vote.changeset(%Vote{}, %{
      account_id: account.id,
      subject_type: subject_type,
      subject_id: subject_id,
      value: value
    })
  end

  defp broadcast(subject_type, subject_id) do
    Phoenix.PubSub.broadcast(Tarakan.PubSub, @topic, {:vote_changed, subject_type, subject_id})
  end
end
