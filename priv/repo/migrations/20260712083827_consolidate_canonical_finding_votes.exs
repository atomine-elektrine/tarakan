defmodule Tarakan.Repo.Migrations.ConsolidateCanonicalFindingVotes do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO votes (
      account_id, subject_type, subject_id, value, inserted_at, updated_at
    )
    SELECT DISTINCT ON (vote.account_id, finding.canonical_finding_id)
      vote.account_id, 'canonical_finding', finding.canonical_finding_id,
      vote.value, vote.inserted_at, vote.updated_at
    FROM votes vote
    JOIN scan_findings finding ON finding.id = vote.subject_id
    WHERE vote.subject_type = 'finding' AND finding.canonical_finding_id IS NOT NULL
    ORDER BY vote.account_id, finding.canonical_finding_id,
      vote.updated_at DESC, vote.id DESC
    ON CONFLICT (account_id, subject_type, subject_id)
    DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
    """

    execute "DELETE FROM votes WHERE subject_type = 'finding'"
  end

  def down do
    execute """
    INSERT INTO votes (
      account_id, subject_type, subject_id, value, inserted_at, updated_at
    )
    SELECT vote.account_id, 'finding', occurrence.id, vote.value,
      vote.inserted_at, vote.updated_at
    FROM votes vote
    JOIN LATERAL (
      SELECT finding.id
      FROM scan_findings finding
      JOIN scans scan ON scan.id = finding.scan_id
      WHERE finding.canonical_finding_id = vote.subject_id
      ORDER BY scan.inserted_at ASC, finding.id ASC
      LIMIT 1
    ) occurrence ON true
    WHERE vote.subject_type = 'canonical_finding'
    ON CONFLICT (account_id, subject_type, subject_id)
    DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
    """

    execute "DELETE FROM votes WHERE subject_type = 'canonical_finding'"
  end
end
