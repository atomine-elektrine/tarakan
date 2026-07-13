defmodule Tarakan.FindingMemory do
  @moduledoc """
  Assimilates immutable report findings into canonical repository issues.

  Only exact deterministic fingerprints auto-link. Agent-provided dispositions
  and canonical IDs are retained as hints but never override server matching.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories.{Repository, RepositoryMembership}
  alias Tarakan.Scans.{CanonicalFinding, Finding, FindingCheck, Scan}

  @counting_provenances ~w(human hybrid)
  @verification_threshold 2

  @doc "Links every finding in a newly inserted scan to canonical memory."
  def assimilate_scan(%Scan{} = scan) do
    scan = Repo.preload(scan, :findings, force: true)

    canonical_ids =
      Enum.map(scan.findings, fn occurrence ->
        fingerprint = fingerprint(occurrence)

        canonical = upsert_canonical(scan, occurrence, fingerprint)

        prior_detections =
          Repo.aggregate(
            from(item in Finding,
              where: item.canonical_finding_id == ^canonical.id,
              select: item.scan_id,
              distinct: true
            ),
            :count
          )

        disposition =
          cond do
            prior_detections == 0 -> "new"
            canonical.status == "fixed" -> "regression"
            occurrence.disposition == "regression" -> "regression"
            true -> "matches_existing"
          end

        occurrence
        |> Ecto.Changeset.change(
          canonical_finding_id: canonical.id,
          fingerprint: fingerprint,
          disposition: disposition
        )
        |> Repo.update!()

        canonical.id
      end)
      |> Enum.uniq()

    Enum.each(canonical_ids, &refresh_canonical/1)
    Repo.preload(scan, [findings: :canonical_finding], force: true)
  end

  @doc "A stable exact-match fingerprint for a normalized finding occurrence."
  def fingerprint(%{file_path: path, line_start: line_start, line_end: line_end, title: title}) do
    [normalize(path), number(line_start), number(line_end), normalize(title)]
    |> Enum.join(<<31>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Lists prompt-safe canonical memory backed by publicly disclosed occurrences."
  def list_repository_memory(%Repository{id: repository_id}, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 200) |> min(500) |> max(1)

    rows =
      Repo.all(
        from canonical in CanonicalFinding,
          join: occurrence in Finding,
          on: occurrence.canonical_finding_id == canonical.id,
          join: scan in Scan,
          on: scan.id == occurrence.scan_id,
          where:
            canonical.repository_id == ^repository_id and
              scan.visibility == "public",
          distinct: canonical.id,
          order_by: [asc: canonical.id, desc: scan.inserted_at, desc: occurrence.id],
          select: {canonical, occurrence, scan.commit_sha},
          limit: ^limit
      )

    rows
    |> Enum.map(fn {canonical, occurrence, commit_sha} ->
      %{
        id: canonical.id,
        public_id: canonical.public_id,
        occurrence_public_id: occurrence.public_id,
        status: canonical.status,
        file_path: occurrence.file_path,
        line_start: occurrence.line_start,
        line_end: occurrence.line_end,
        severity: occurrence.severity,
        title: occurrence.title,
        description: occurrence.description,
        first_seen_commit_sha: canonical.first_seen_commit_sha,
        last_seen_commit_sha: canonical.last_seen_commit_sha || commit_sha,
        detections_count: canonical.detections_count,
        distinct_submitters_count: canonical.distinct_submitters_count,
        distinct_models_count: canonical.distinct_models_count,
        confirmations_count: canonical.confirmations_count,
        disputes_count: canonical.disputes_count
      }
    end)
    |> Enum.sort_by(&{status_rank(&1.status), -&1.detections_count, &1.file_path})
  end

  @doc "Finds one canonical issue by its non-enumerable public ID."
  def get(repository, public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id),
         %CanonicalFinding{} = finding <-
           Repo.get_by(CanonicalFinding, repository_id: repository.id, public_id: public_id) do
      {:ok, finding}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "Records an independent per-finding check at a specific commit."
  def record_check(
        %Scope{account: %Account{} = account} = scope,
        %Repository{} = repository,
        public_id,
        attrs
      ) do
    attrs = stringify_keys(attrs)

    with {:ok, canonical} <- get(repository, public_id),
         commit_sha when is_binary(commit_sha) <- attrs["commit_sha"],
         %Finding{} = occurrence <- occurrence_for_check(canonical.id, commit_sha) do
      Repo.transaction(fn ->
        locked_repository =
          Repo.one!(
            from item in Repository,
              where: item.id == ^repository.id,
              lock: "FOR UPDATE"
          )

        fresh_account =
          Repo.one!(
            from item in Account,
              where: item.id == ^account.id,
              lock: "FOR UPDATE"
          )

        canonical =
          Repo.one!(
            from item in CanonicalFinding,
              where: item.id == ^canonical.id,
              lock: "FOR UPDATE"
          )

        fresh_scope =
          case Accounts.refresh_scope_for_account(fresh_account, scope) do
            {:ok, refreshed} -> refreshed
            {:error, reason} -> Repo.rollback(reason)
          end

        scan = %{Repo.get!(Scan, occurrence.scan_id) | repository: locked_repository}

        with :ok <- Policy.authorize(fresh_scope, :verify_review, scan),
             :ok <- ensure_independent(canonical.id, commit_sha, fresh_account.id) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end

        check =
          %FindingCheck{
            canonical_finding_id: canonical.id,
            scan_finding_id: occurrence.id,
            account_id: fresh_account.id
          }
          |> FindingCheck.changeset(attrs)

        case Repo.insert(check) do
          {:ok, inserted} ->
            refresh_canonical_checks(canonical.id)
            Tarakan.Scans.recalculate_repository_metrics(repository.id)
            inserted

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, check} ->
          refresh_scans_for_check(canonical.id, check.commit_sha)
          {:ok, check, Repo.get!(CanonicalFinding, canonical.id)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :commit_not_found}
      error -> error
    end
  end

  def record_check(_scope, _repository, _public_id, _attrs), do: {:error, :unauthorized}

  @doc "Whether a scope may independently check this canonical finding."
  def can_check?(
        %Scope{account: %Account{id: account_id}} = scope,
        repository,
        public_id,
        commit_sha
      ) do
    with {:ok, canonical} <- get(repository, public_id),
         %Finding{} = occurrence <- occurrence_for_check(canonical.id, commit_sha),
         scan <- Repo.get!(Scan, occurrence.scan_id) |> Repo.preload(:repository),
         :ok <- Policy.authorize(scope, :verify_review, scan),
         :ok <- ensure_independent(canonical.id, commit_sha, account_id),
         :ok <- ensure_not_checked(canonical.id, commit_sha, account_id) do
      true
    else
      _reason -> false
    end
  end

  def can_check?(_scope, _repository, _public_id, _commit_sha), do: false

  @doc "Lists the named checks behind a canonical tally at one commit."
  def list_checks(canonical_id, commit_sha)
      when is_integer(canonical_id) and is_binary(commit_sha) do
    Repo.all(
      from check in FindingCheck,
        join: canonical in assoc(check, :canonical_finding),
        join: account in assoc(check, :account),
        left_join: membership in RepositoryMembership,
        on:
          membership.repository_id == canonical.repository_id and
            membership.account_id == account.id and membership.status == "verified" and
            membership.role in ["reviewer", "steward"],
        where: check.canonical_finding_id == ^canonical_id and check.commit_sha == ^commit_sha,
        order_by: [desc: check.inserted_at, desc: check.id],
        select: {
          check,
          account,
          check.provenance in ^@counting_provenances and
            account.state in ["probation", "active"] and
            (account.trust_tier == "reviewer" or
               account.platform_role in ["moderator", "admin"] or not is_nil(membership.id))
        }
    )
    |> Enum.map(fn {check, account, counts_toward_quorum} ->
      %{
        id: check.id,
        verdict: check.verdict,
        provenance: check.provenance,
        notes: check.notes,
        evidence: check.evidence,
        inserted_at: check.inserted_at,
        account: account,
        counts_toward_quorum: counts_toward_quorum
      }
    end)
  end

  def list_checks(_canonical_id, _commit_sha), do: []

  @doc "Returns the public IDs the current account may check, using batched conflict queries."
  def checkable_public_ids(
        %Scope{account: %Account{id: account_id}} = scope,
        %Repository{} = repository,
        findings
      )
      when is_list(findings) do
    subject = %Scan{repository: repository, repository_id: repository.id}

    if findings == [] or not Policy.allowed?(scope, :verify_review, subject) do
      MapSet.new()
    else
      canonical_ids = Enum.map(findings, & &1.id)

      authored_pairs =
        Repo.all(
          from occurrence in Finding,
            join: scan in Scan,
            on: scan.id == occurrence.scan_id,
            where:
              occurrence.canonical_finding_id in ^canonical_ids and
                scan.submitted_by_id == ^account_id,
            select: {occurrence.canonical_finding_id, scan.commit_sha},
            distinct: true
        )
        |> MapSet.new()

      checked_pairs =
        Repo.all(
          from check in FindingCheck,
            where:
              check.canonical_finding_id in ^canonical_ids and check.account_id == ^account_id,
            select: {check.canonical_finding_id, check.commit_sha}
        )
        |> MapSet.new()

      findings
      |> Enum.reject(fn finding ->
        pair = {finding.id, finding.last_seen_commit_sha}
        MapSet.member?(authored_pairs, pair) or MapSet.member?(checked_pairs, pair)
      end)
      |> Enum.map(& &1.public_id)
      |> MapSet.new()
    end
  end

  def checkable_public_ids(_scope, _repository, _findings), do: MapSet.new()

  @doc "Whether every finding occurrence in a report has canonical check quorum at its commit."
  def scan_verified?(%Scan{} = scan) do
    canonical_ids =
      Repo.all(
        from occurrence in Finding,
          where: occurrence.scan_id == ^scan.id and not is_nil(occurrence.canonical_finding_id),
          select: occurrence.canonical_finding_id,
          distinct: true
      )

    if canonical_ids == [] do
      not is_nil(scan.verified_at)
    else
      tallies = qualified_check_tallies(scan.repository_id, canonical_ids, scan.commit_sha)

      Enum.all?(canonical_ids, fn canonical_id ->
        tally = Map.get(tallies, canonical_id, %{confirmed: 0, disputed: 0, fixed: 0})

        tally.confirmed - tally.disputed >= @verification_threshold or
          tally.fixed - tally.disputed >= @verification_threshold
      end)
    end
  end

  @doc "Recomputes canonical check quorum after account or membership authority changes."
  def refresh_repository_checks(repository_id) when is_integer(repository_id) do
    canonical_ids =
      Repo.all(
        from canonical in CanonicalFinding,
          where: canonical.repository_id == ^repository_id,
          select: canonical.id
      )

    Enum.each(canonical_ids, &refresh_canonical_checks/1)

    Repo.all(
      from scan in Scan,
        where: scan.repository_id == ^repository_id,
        select: scan.id
    )
    |> Enum.each(&refresh_scan_verification/1)

    :ok
  end

  @doc "Copies a legacy report-level verdict onto each canonical finding occurrence."
  def assimilate_report_check(%Scan{} = scan, confirmation, account) do
    occurrences =
      Repo.all(
        from occurrence in Finding,
          where: occurrence.scan_id == ^scan.id and not is_nil(occurrence.canonical_finding_id)
      )

    canonical_ids =
      Enum.map(occurrences, fn occurrence ->
        attrs = %{
          "commit_sha" => scan.commit_sha,
          "verdict" => confirmation.verdict,
          "provenance" => confirmation.provenance,
          "notes" => confirmation.notes,
          "evidence" => confirmation.evidence
        }

        %FindingCheck{
          canonical_finding_id: occurrence.canonical_finding_id,
          scan_finding_id: occurrence.id,
          account_id: account.id
        }
        |> FindingCheck.changeset(attrs)
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: [:canonical_finding_id, :account_id, :commit_sha]
        )

        occurrence.canonical_finding_id
      end)
      |> Enum.uniq()

    Enum.each(canonical_ids, &refresh_canonical_checks/1)
    :ok
  end

  defp upsert_canonical(scan, occurrence, fingerprint) do
    attrs = %{
      repository_id: scan.repository_id,
      fingerprint: fingerprint,
      file_path: occurrence.file_path,
      line_start: occurrence.line_start,
      line_end: occurrence.line_end,
      severity: occurrence.severity,
      title: occurrence.title,
      description: occurrence.description,
      first_seen_commit_sha: scan.commit_sha,
      last_seen_commit_sha: scan.commit_sha
    }

    %CanonicalFinding{}
    |> CanonicalFinding.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:repository_id, :fingerprint]
    )

    Repo.get_by!(CanonicalFinding, repository_id: scan.repository_id, fingerprint: fingerprint)
  end

  defp refresh_canonical(canonical_id) do
    stats =
      Repo.one!(
        from occurrence in Finding,
          join: scan in Scan,
          on: scan.id == occurrence.scan_id,
          where: occurrence.canonical_finding_id == ^canonical_id,
          select: %{
            detections: count(scan.id, :distinct),
            submitters: count(scan.submitted_by_id, :distinct),
            models: count(scan.model, :distinct),
            first_seen: min(scan.inserted_at),
            last_seen: max(scan.inserted_at)
          }
      )

    first_commit = commit_at(canonical_id, stats.first_seen, :asc)
    last_commit = commit_at(canonical_id, stats.last_seen, :desc)

    canonical = Repo.get!(CanonicalFinding, canonical_id)

    canonical
    |> Ecto.Changeset.change(
      detections_count: stats.detections,
      distinct_submitters_count: stats.submitters,
      distinct_models_count: stats.models,
      first_seen_commit_sha: first_commit,
      last_seen_commit_sha: last_commit
    )
    |> Repo.update!()

    refresh_canonical_checks(canonical_id)
  end

  defp commit_at(canonical_id, _timestamp, :asc) do
    Repo.one!(
      from occurrence in Finding,
        join: scan in Scan,
        on: scan.id == occurrence.scan_id,
        where: occurrence.canonical_finding_id == ^canonical_id,
        order_by: [asc: scan.inserted_at, asc: occurrence.id],
        limit: 1,
        select: scan.commit_sha
    )
  end

  defp commit_at(canonical_id, _timestamp, :desc) do
    Repo.one!(
      from occurrence in Finding,
        join: scan in Scan,
        on: scan.id == occurrence.scan_id,
        where: occurrence.canonical_finding_id == ^canonical_id,
        order_by: [desc: scan.inserted_at, desc: occurrence.id],
        limit: 1,
        select: scan.commit_sha
    )
  end

  defp refresh_canonical_checks(canonical_id) do
    canonical = Repo.get!(CanonicalFinding, canonical_id)

    tallies =
      Repo.one!(
        from check in FindingCheck,
          join: account in Account,
          on: account.id == check.account_id,
          left_join: membership in RepositoryMembership,
          on:
            membership.repository_id == ^canonical.repository_id and
              membership.account_id == account.id and membership.status == "verified" and
              membership.role in ["reviewer", "steward"],
          where:
            check.canonical_finding_id == ^canonical.id and
              check.commit_sha == ^canonical.last_seen_commit_sha and
              check.provenance in ^@counting_provenances and
              account.state in ["probation", "active"] and
              (account.trust_tier == "reviewer" or
                 account.platform_role in ["moderator", "admin"] or not is_nil(membership.id)),
          select: %{
            confirmed: count(check.id) |> filter(check.verdict == "confirmed"),
            disputed: count(check.id) |> filter(check.verdict == "disputed"),
            fixed: count(check.id) |> filter(check.verdict == "fixed")
          }
      )

    {status, verified_at} =
      cond do
        tallies.fixed - tallies.disputed >= @verification_threshold ->
          {"fixed", canonical.verified_at || DateTime.utc_now()}

        tallies.confirmed - tallies.disputed >= @verification_threshold ->
          {"verified", canonical.verified_at || DateTime.utc_now()}

        tallies.disputed > tallies.confirmed ->
          {"disputed", nil}

        true ->
          {"open", nil}
      end

    canonical
    |> Ecto.Changeset.change(
      status: status,
      confirmations_count: tallies.confirmed,
      disputes_count: tallies.disputed,
      verified_at: verified_at
    )
    |> Repo.update!()
  end

  defp qualified_check_tallies(repository_id, canonical_ids, commit_sha) do
    Repo.all(
      from check in FindingCheck,
        join: account in Account,
        on: account.id == check.account_id,
        left_join: membership in RepositoryMembership,
        on:
          membership.repository_id == ^repository_id and
            membership.account_id == account.id and membership.status == "verified" and
            membership.role in ["reviewer", "steward"],
        where:
          check.canonical_finding_id in ^canonical_ids and check.commit_sha == ^commit_sha and
            check.provenance in ^@counting_provenances and
            account.state in ["probation", "active"] and
            (account.trust_tier == "reviewer" or
               account.platform_role in ["moderator", "admin"] or not is_nil(membership.id)),
        group_by: check.canonical_finding_id,
        select: {
          check.canonical_finding_id,
          %{
            confirmed: count(check.id) |> filter(check.verdict == "confirmed"),
            disputed: count(check.id) |> filter(check.verdict == "disputed"),
            fixed: count(check.id) |> filter(check.verdict == "fixed")
          }
        }
    )
    |> Map.new()
  end

  defp refresh_scans_for_check(canonical_id, commit_sha) do
    Repo.all(
      from occurrence in Finding,
        join: scan in Scan,
        on: scan.id == occurrence.scan_id,
        where:
          occurrence.canonical_finding_id == ^canonical_id and scan.commit_sha == ^commit_sha,
        select: scan.id,
        distinct: true
    )
    |> Enum.each(&refresh_scan_verification/1)
  end

  defp refresh_scan_verification(scan_id) do
    scan = Repo.get!(Scan, scan_id)
    verified? = scan_verified?(scan)

    changeset =
      cond do
        verified? ->
          Ecto.Changeset.change(scan, verified_at: scan.verified_at || DateTime.utc_now())

        scan.review_status == "accepted" ->
          Scan.quorum_lost_changeset(scan)

        true ->
          Ecto.Changeset.change(scan, verified_at: nil)
      end

    Repo.update!(changeset)
  end

  defp occurrence_for_check(canonical_id, commit_sha) do
    Repo.one(
      from occurrence in Finding,
        join: scan in Scan,
        on: scan.id == occurrence.scan_id,
        where:
          occurrence.canonical_finding_id == ^canonical_id and scan.commit_sha == ^commit_sha and
            scan.visibility == "public",
        order_by: [desc: scan.inserted_at, desc: occurrence.id],
        limit: 1,
        select: occurrence
    )
  end

  defp ensure_independent(canonical_id, commit_sha, account_id) do
    authored? =
      Repo.exists?(
        from occurrence in Finding,
          join: scan in Scan,
          on: scan.id == occurrence.scan_id,
          where:
            occurrence.canonical_finding_id == ^canonical_id and
              scan.commit_sha == ^commit_sha and scan.submitted_by_id == ^account_id
      )

    if authored?, do: {:error, :conflict_of_interest}, else: :ok
  end

  defp ensure_not_checked(canonical_id, commit_sha, account_id) do
    checked? =
      Repo.exists?(
        from check in FindingCheck,
          where:
            check.canonical_finding_id == ^canonical_id and
              check.commit_sha == ^commit_sha and check.account_id == ^account_id
      )

    if checked?, do: {:error, :already_checked}, else: :ok
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end

  defp number(nil), do: ""
  defp number(value), do: to_string(value)

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp status_rank("open"), do: 0
  defp status_rank("disputed"), do: 1
  defp status_rank("verified"), do: 2
  defp status_rank("fixed"), do: 3
  defp status_rank(_status), do: 4
end
