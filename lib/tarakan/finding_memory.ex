defmodule Tarakan.FindingMemory do
  @moduledoc """
  Assimilates immutable report findings into canonical repository issues.

  Only deterministic fingerprints auto-link (no embeddings / LLM merge).
  Matching is exact on normalized path + line_start + title. Agent-provided
  dispositions and canonical IDs are retained as hints but never override
  server matching.

  Path/title normalization collapses common agent variants (`./path`,
  confidence prefixes, punctuation). A legacy fingerprint is still consulted
  so pre-existing canonical rows keep accumulating detections after upgrades.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Abuse
  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.ContentSafety
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.RepositoryPath
  alias Tarakan.Repositories.{Repository, RepositoryMembership}
  alias Tarakan.Scans.{CanonicalFinding, Finding, FindingCheck, Scan}

  @counting_provenances ~w(human hybrid)
  @verification_threshold 2
  @quorum_states ["active"]

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

  @doc """
  Stable fingerprint for a normalized finding occurrence.

  Uses repository-relative path (canonicalized), **line_start only** (line_end
  is display/range noise across agents), and normalized title.
  """
  def fingerprint(%{file_path: path, line_start: line_start, title: title}) do
    hash_parts([
      normalize_path(path),
      number(line_start),
      normalize_title(title)
    ])
  end

  @doc false
  # Frozen v1 algorithm (path + start + end + title) for upgrade lookup only.
  def legacy_fingerprint(%{
        file_path: path,
        line_start: line_start,
        line_end: line_end,
        title: title
      }) do
    hash_parts([
      legacy_normalize(path),
      number(line_start),
      number(line_end),
      legacy_normalize(title)
    ])
  end

  @doc """
  Cross-repository epidemic key: normalized title only.

  Same class of issue in different repos/paths share a pattern_key even when
  the full fingerprint differs.
  """
  def pattern_key(%{title: title}), do: pattern_key(title)

  def pattern_key(title) when is_binary(title) do
    title
    |> normalize_title()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def pattern_key(_), do: pattern_key("")

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
      last_sha = canonical.last_seen_commit_sha || commit_sha

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
        last_seen_commit_sha: last_sha,
        detections_count: canonical.detections_count,
        distinct_submitters_count: canonical.distinct_submitters_count,
        distinct_models_count: canonical.distinct_models_count,
        confirmations_count: canonical.confirmations_count,
        disputes_count: canonical.disputes_count,
        trust: trust_summary(canonical, last_sha)
      }
    end)
    |> Enum.sort_by(&evidence_sort_key/1)
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

        check_attrs =
          attrs
          |> Map.put("client_ip_hash", Abuse.hash_client_ip(attrs["client_ip"]))
          |> Map.delete("client_ip")

        with :ok <- ContentSafety.scan_text(check_attrs["notes"]),
             :ok <- ContentSafety.scan_text(check_attrs["evidence"]) do
          :ok
        else
          {:error, :secrets_detected} -> Repo.rollback(:secrets_detected)
        end

        check =
          %FindingCheck{
            canonical_finding_id: canonical.id,
            scan_finding_id: occurrence.id,
            account_id: fresh_account.id
          }
          |> FindingCheck.changeset(check_attrs)

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
          updated = Repo.get!(CanonicalFinding, canonical.id)

          if is_binary(updated.pattern_key) and updated.pattern_key != "" do
            _ =
              Tarakan.Epidemics.schedule_refresh_after_commit([updated.pattern_key],
                reason: :status
              )
          end

          {:ok, check, updated}

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
        select: {check, account, membership}
    )
    |> Enum.map(fn {check, account, membership} ->
      counts? =
        check_counts_toward_quorum?(
          check,
          account,
          membership
        )

      %{
        id: check.id,
        verdict: check.verdict,
        provenance: check.provenance,
        notes: check.notes,
        evidence: check.evidence,
        inserted_at: check.inserted_at,
        account: account,
        counts_toward_quorum: counts?
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
    pattern = pattern_key(occurrence)

    case get_canonical(scan.repository_id, fingerprint) ||
           upgrade_legacy_canonical(scan.repository_id, occurrence, fingerprint, pattern) do
      %CanonicalFinding{} = existing ->
        existing

      nil ->
        attrs = %{
          repository_id: scan.repository_id,
          fingerprint: fingerprint,
          pattern_key: pattern,
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
          on_conflict: {:replace, [:pattern_key]},
          conflict_target: [:repository_id, :fingerprint]
        )

        get_canonical(scan.repository_id, fingerprint) ||
          Repo.get_by!(CanonicalFinding,
            repository_id: scan.repository_id,
            fingerprint: fingerprint
          )
    end
  end

  defp get_canonical(repository_id, fingerprint) do
    Repo.get_by(CanonicalFinding, repository_id: repository_id, fingerprint: fingerprint)
  end

  # If an older report created a v1 fingerprint, re-key it to v2 so new reports merge.
  defp upgrade_legacy_canonical(repository_id, occurrence, fingerprint, pattern) do
    legacy = legacy_fingerprint(occurrence)

    if legacy == fingerprint do
      nil
    else
      case get_canonical(repository_id, legacy) do
        %CanonicalFinding{} = existing ->
          existing
          |> Ecto.Changeset.change(fingerprint: fingerprint, pattern_key: pattern)
          |> Repo.update!()

        nil ->
          nil
      end
    end
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

    # Load candidate checks then filter collusion in Elixir (IP hash rules).
    candidates =
      Repo.all(
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
              account.state in ^@quorum_states and
              (account.trust_tier == "reviewer" or
                 account.platform_role in ["moderator", "admin"] or not is_nil(membership.id)),
          select: check
      )
      |> Enum.reject(fn check ->
        Abuse.colluding_ip_check?(canonical.id, check.account_id, check.client_ip_hash)
      end)

    tallies = %{
      confirmed: Enum.count(candidates, &(&1.verdict == "confirmed")),
      disputed: Enum.count(candidates, &(&1.verdict == "disputed")),
      fixed: Enum.count(candidates, &(&1.verdict == "fixed"))
    }

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
            account.state in ^@quorum_states and
            (account.trust_tier == "reviewer" or
               account.platform_role in ["moderator", "admin"] or not is_nil(membership.id)),
        select: check
    )
    |> Enum.reject(fn check ->
      Abuse.colluding_ip_check?(
        check.canonical_finding_id,
        check.account_id,
        check.client_ip_hash
      )
    end)
    |> Enum.group_by(& &1.canonical_finding_id)
    |> Map.new(fn {canonical_id, checks} ->
      {canonical_id,
       %{
         confirmed: Enum.count(checks, &(&1.verdict == "confirmed")),
         disputed: Enum.count(checks, &(&1.verdict == "disputed")),
         fixed: Enum.count(checks, &(&1.verdict == "fixed"))
       }}
    end)
  end

  defp check_counts_toward_quorum?(check, account, membership) do
    check.provenance in @counting_provenances and
      account.state in @quorum_states and
      (account.trust_tier == "reviewer" or
         account.platform_role in ["moderator", "admin"] or not is_nil(membership)) and
      not Abuse.colluding_ip_check?(
        check.canonical_finding_id,
        check.account_id,
        check.client_ip_hash
      )
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

  @doc """
  Trust chips for UI: reported always; agent_reproduced / human_checked from checks.

  Agent checks never alone equal quorum; human_checked means a qualified
  human/hybrid confirmation exists at this commit.
  """
  def trust_summary(%CanonicalFinding{} = canonical, commit_sha)
      when is_binary(commit_sha) and commit_sha != "" do
    checks = list_checks(canonical.id, commit_sha)

    agent_reproduced =
      Enum.any?(checks, fn c -> c.verdict == "confirmed" and c.provenance == "agent" end)

    human_checked =
      Enum.any?(checks, fn c ->
        c.verdict in ["confirmed", "fixed"] and c.counts_toward_quorum
      end)

    agent_disputed =
      Enum.any?(checks, fn c -> c.verdict == "disputed" and c.provenance == "agent" end)

    %{
      reported: true,
      agent_reproduced: agent_reproduced,
      agent_disputed: agent_disputed,
      human_checked: human_checked,
      verified: canonical.status == "verified",
      disputed: canonical.status == "disputed",
      fixed: canonical.status == "fixed"
    }
  end

  def trust_summary(_canonical, _commit_sha) do
    %{
      reported: true,
      agent_reproduced: false,
      agent_disputed: false,
      human_checked: false,
      verified: false,
      disputed: false,
      fixed: false
    }
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

  defp hash_parts(parts) do
    parts
    |> Enum.join(<<31>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_path(path), do: RepositoryPath.fingerprint_form(path)

  # Aggressive normalize so near-duplicate agent dumps assimilate (spam collapse).
  defp normalize_title(value) do
    value
    |> to_string()
    |> String.downcase()
    |> strip_confidence_prefixes()
    |> String.replace(~r/[^\p{L}\p{N}\s\/\.\-_]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_trailing(".")
  end

  # Frozen copy of the pre-v2 title/path normalizer for legacy fingerprints.
  defp legacy_normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(
      ~r/^(verified|hypothesis(?:\/low)?|unverified|likely|possible|confirmed)\s*:\s*/iu,
      ""
    )
    |> String.replace(~r/[^\p{L}\p{N}\s\/\.\-_]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp strip_confidence_prefixes(title) do
    # Repeatedly strip agent boilerplate so "Verified: Likely: X" collapses.
    prefixes =
      ~r/^(?:verified|hypothesis(?:\/low)?|unverified|likely|possible|confirmed|warning|error|critical|high|medium|low|info|cwe[-\s]?\d+)\s*:\s*/iu

    next = String.replace(title, prefixes, "")
    if next == title, do: title, else: strip_confidence_prefixes(next)
  end

  defp number(nil), do: ""
  defp number(value), do: to_string(value)

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  # Lower sorts first: verified, then checked, then open, then fixed.
  defp evidence_sort_key(finding) do
    trust = finding.trust || %{}

    tier =
      cond do
        finding.status == "verified" or trust[:verified] == true ->
          0

        trust[:human_checked] == true ->
          1

        finding.status == "open" and trust[:agent_reproduced] == true and
            trust[:agent_disputed] != true ->
          2

        finding.status == "open" ->
          3

        finding.status == "disputed" or trust[:disputed] == true ->
          4

        finding.status == "fixed" or trust[:fixed] == true ->
          5

        true ->
          6
      end

    severity_rank =
      case finding.severity do
        "critical" -> 0
        "high" -> 1
        "medium" -> 2
        "low" -> 3
        _ -> 4
      end

    {tier, severity_rank, -(finding.confirmations_count || 0), -(finding.detections_count || 0),
     finding.file_path || ""}
  end
end
