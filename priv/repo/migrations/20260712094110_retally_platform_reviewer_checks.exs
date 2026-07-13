defmodule Tarakan.Repo.Migrations.RetallyPlatformReviewerChecks do
  use Ecto.Migration

  def up do
    execute """
    WITH tallies AS (
      SELECT canonical.id,
        count(check_record.id) FILTER (
          WHERE check_record.verdict = 'confirmed'
            AND check_record.provenance IN ('human', 'hybrid')
            AND account.state IN ('probation', 'active')
            AND (
              account.trust_tier = 'reviewer'
              OR account.platform_role IN ('moderator', 'admin')
              OR membership.id IS NOT NULL
            )
        ) AS confirmed,
        count(check_record.id) FILTER (
          WHERE check_record.verdict = 'disputed'
            AND check_record.provenance IN ('human', 'hybrid')
            AND account.state IN ('probation', 'active')
            AND (
              account.trust_tier = 'reviewer'
              OR account.platform_role IN ('moderator', 'admin')
              OR membership.id IS NOT NULL
            )
        ) AS disputed,
        count(check_record.id) FILTER (
          WHERE check_record.verdict = 'fixed'
            AND check_record.provenance IN ('human', 'hybrid')
            AND account.state IN ('probation', 'active')
            AND (
              account.trust_tier = 'reviewer'
              OR account.platform_role IN ('moderator', 'admin')
              OR membership.id IS NOT NULL
            )
        ) AS fixed
      FROM canonical_findings canonical
      LEFT JOIN canonical_finding_checks check_record
        ON check_record.canonical_finding_id = canonical.id
        AND check_record.commit_sha = canonical.last_seen_commit_sha
      LEFT JOIN accounts account ON account.id = check_record.account_id
      LEFT JOIN repository_memberships membership
        ON membership.repository_id = canonical.repository_id
        AND membership.account_id = account.id
        AND membership.status = 'verified'
        AND membership.role IN ('reviewer', 'steward')
      GROUP BY canonical.id
    ), resolved AS (
      SELECT tallies.*,
        CASE
          WHEN fixed - disputed >= 2 THEN 'fixed'
          WHEN confirmed - disputed >= 2 THEN 'verified'
          WHEN disputed > confirmed THEN 'disputed'
          ELSE 'open'
        END AS status
      FROM tallies
    )
    UPDATE canonical_findings canonical
    SET confirmations_count = resolved.confirmed,
        disputes_count = resolved.disputed,
        status = resolved.status,
        verified_at = CASE
          WHEN resolved.status IN ('verified', 'fixed')
            THEN coalesce(canonical.verified_at, now())
          ELSE NULL
        END,
        updated_at = now()
    FROM resolved
    WHERE canonical.id = resolved.id
    """

    execute """
    WITH public_canonical AS (
      SELECT DISTINCT scan.repository_id, finding.canonical_finding_id
      FROM scan_findings finding
      JOIN scans scan ON scan.id = finding.scan_id
      WHERE scan.visibility IN ('public_summary', 'public')
        AND finding.canonical_finding_id IS NOT NULL
    ), metrics AS (
      SELECT repository.id,
        count(public_canonical.canonical_finding_id) FILTER (
          WHERE canonical.status != 'fixed'
        ) AS open_count,
        count(public_canonical.canonical_finding_id) FILTER (
          WHERE canonical.status = 'verified'
        ) AS verified_count
      FROM repositories repository
      LEFT JOIN public_canonical ON public_canonical.repository_id = repository.id
      LEFT JOIN canonical_findings canonical
        ON canonical.id = public_canonical.canonical_finding_id
      GROUP BY repository.id
    )
    UPDATE repositories repository
    SET open_findings_count = metrics.open_count,
        verified_findings_count = metrics.verified_count,
        status = CASE
          WHEN repository.scan_count = 0 THEN 'unscanned'
          WHEN metrics.open_count > 0 THEN 'findings'
          ELSE 'reviewed'
        END,
        updated_at = now()
    FROM metrics
    WHERE repository.id = metrics.id
    """
  end

  def down do
    # Data was previously under-counted; restoring incorrect tallies would be destructive.
    :ok
  end
end
