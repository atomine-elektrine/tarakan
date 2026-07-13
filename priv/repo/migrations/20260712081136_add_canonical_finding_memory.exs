defmodule Tarakan.Repo.Migrations.AddCanonicalFindingMemory do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    alter table(:scans) do
      add :run_id, :string
    end

    drop_if_exists index(
                     :scans,
                     [
                       :repository_id,
                       :submitted_by_id,
                       :commit_sha,
                       :provenance,
                       :review_kind,
                       "COALESCE(model, '')",
                       "COALESCE(prompt_version, '')"
                     ],
                     name: :scans_unique_submission_index
                   )

    create unique_index(:scans, [:submitted_by_id, :run_id],
             where: "run_id IS NOT NULL",
             name: :scans_unique_run_index
           )

    create table(:canonical_findings) do
      add :public_id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :fingerprint, :string, null: false, size: 64
      add :file_path, :string, null: false, size: 500
      add :line_start, :integer
      add :line_end, :integer
      add :severity, :string, null: false
      add :title, :string, null: false
      add :description, :text, null: false
      add :status, :string, null: false, default: "open"
      add :first_seen_commit_sha, :string, null: false
      add :last_seen_commit_sha, :string, null: false
      add :detections_count, :integer, null: false, default: 0
      add :distinct_submitters_count, :integer, null: false, default: 0
      add :distinct_models_count, :integer, null: false, default: 0
      add :confirmations_count, :integer, null: false, default: 0
      add :disputes_count, :integer, null: false, default: 0
      add :verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:canonical_findings, [:public_id])
    create unique_index(:canonical_findings, [:repository_id, :fingerprint])
    create index(:canonical_findings, [:repository_id, :status])

    create constraint(:canonical_findings, :canonical_findings_status_must_be_valid,
             check: "status IN ('open', 'verified', 'disputed', 'fixed')"
           )

    create constraint(:canonical_findings, :canonical_findings_counts_must_be_nonnegative,
             check:
               "detections_count >= 0 AND distinct_submitters_count >= 0 AND distinct_models_count >= 0 AND confirmations_count >= 0 AND disputes_count >= 0"
           )

    alter table(:scan_findings) do
      add :canonical_finding_id, references(:canonical_findings, on_delete: :restrict)
      add :fingerprint, :string, size: 64
      add :disposition, :string, null: false, default: "new"
      add :claimed_canonical_public_id, :uuid
    end

    create index(:scan_findings, [:canonical_finding_id])
    create index(:scan_findings, [:fingerprint])

    create constraint(:scan_findings, :scan_findings_disposition_must_be_valid,
             check: "disposition IN ('new', 'matches_existing', 'regression', 'not_reproduced')"
           )

    create table(:canonical_finding_checks) do
      add :canonical_finding_id, references(:canonical_findings, on_delete: :delete_all),
        null: false

      add :scan_finding_id, references(:scan_findings, on_delete: :nilify_all)
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :commit_sha, :string, null: false
      add :verdict, :string, null: false
      add :provenance, :string, null: false, default: "human"
      add :notes, :text, null: false
      add :evidence, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :canonical_finding_checks,
             [:canonical_finding_id, :account_id, :commit_sha],
             name: :canonical_finding_checks_unique_actor_commit_index
           )

    create index(:canonical_finding_checks, [:account_id])

    create constraint(:canonical_finding_checks, :canonical_finding_checks_verdict_must_be_valid,
             check: "verdict IN ('confirmed', 'disputed', 'fixed')"
           )

    create constraint(
             :canonical_finding_checks,
             :canonical_finding_checks_provenance_must_be_valid,
             check: "provenance IN ('agent', 'human', 'hybrid')"
           )

    execute """
    WITH source AS (
      SELECT sf.*, s.repository_id, s.commit_sha, s.model, s.submitted_by_id,
        s.verified_at AS scan_verified_at,
        encode(digest(concat_ws(E'\\x1f', lower(trim(sf.file_path)),
          coalesce(sf.line_start::text, ''), coalesce(sf.line_end::text, ''),
          regexp_replace(lower(trim(sf.title)), '\\s+', ' ', 'g')), 'sha256'), 'hex') AS fp
      FROM scan_findings sf
      JOIN scans s ON s.id = sf.scan_id
    ), representatives AS (
      SELECT DISTINCT ON (repository_id, fp) *
      FROM source
      ORDER BY repository_id, fp, inserted_at ASC, id ASC
    )
    INSERT INTO canonical_findings (
      public_id, repository_id, fingerprint, file_path, line_start, line_end,
      severity, title, description, status, first_seen_commit_sha,
      last_seen_commit_sha, detections_count, distinct_submitters_count,
      distinct_models_count, confirmations_count, disputes_count, verified_at,
      inserted_at, updated_at
    )
    SELECT gen_random_uuid(), representative.repository_id, representative.fp,
      representative.file_path, representative.line_start, representative.line_end,
      representative.severity, representative.title, representative.description,
      CASE WHEN bool_or(source.scan_verified_at IS NOT NULL) THEN 'verified' ELSE 'open' END,
      (array_agg(source.commit_sha ORDER BY source.inserted_at ASC, source.id ASC))[1],
      (array_agg(source.commit_sha ORDER BY source.inserted_at DESC, source.id DESC))[1],
      count(source.id), count(DISTINCT source.submitted_by_id),
      count(DISTINCT source.model) FILTER (WHERE source.model IS NOT NULL),
      0, 0, min(source.scan_verified_at), now(), now()
    FROM representatives representative
    JOIN source ON source.repository_id = representative.repository_id AND source.fp = representative.fp
    GROUP BY representative.repository_id, representative.fp, representative.file_path,
      representative.line_start, representative.line_end, representative.severity,
      representative.title, representative.description
    """

    execute """
    UPDATE scan_findings sf
    SET fingerprint = source.fp,
        canonical_finding_id = canonical.id,
        disposition = CASE WHEN canonical.detections_count > 1 THEN 'matches_existing' ELSE 'new' END
    FROM (
      SELECT sf2.id, s.repository_id,
        encode(digest(concat_ws(E'\\x1f', lower(trim(sf2.file_path)),
          coalesce(sf2.line_start::text, ''), coalesce(sf2.line_end::text, ''),
          regexp_replace(lower(trim(sf2.title)), '\\s+', ' ', 'g')), 'sha256'), 'hex') AS fp
      FROM scan_findings sf2
      JOIN scans s ON s.id = sf2.scan_id
    ) source
    JOIN canonical_findings canonical
      ON canonical.repository_id = source.repository_id AND canonical.fingerprint = source.fp
    WHERE sf.id = source.id
    """

    execute """
    INSERT INTO canonical_finding_checks (
      canonical_finding_id, scan_finding_id, account_id, commit_sha,
      verdict, provenance, notes, evidence, inserted_at, updated_at
    )
    SELECT DISTINCT ON (sf.canonical_finding_id, confirmation.account_id, scan.commit_sha)
      sf.canonical_finding_id, sf.id, confirmation.account_id, scan.commit_sha,
      confirmation.verdict, confirmation.provenance, confirmation.notes,
      confirmation.evidence, confirmation.inserted_at, confirmation.inserted_at
    FROM scan_confirmations confirmation
    JOIN scans scan ON scan.id = confirmation.scan_id
    JOIN scan_findings sf ON sf.scan_id = scan.id
    WHERE sf.canonical_finding_id IS NOT NULL
    ORDER BY sf.canonical_finding_id, confirmation.account_id, scan.commit_sha,
      confirmation.inserted_at ASC, confirmation.id ASC
    ON CONFLICT (canonical_finding_id, account_id, commit_sha) DO NOTHING
    """
  end

  def down do
    drop table(:canonical_finding_checks)

    alter table(:scan_findings) do
      remove :claimed_canonical_public_id
      remove :disposition
      remove :fingerprint
      remove :canonical_finding_id
    end

    drop table(:canonical_findings)
    drop index(:scans, [:submitted_by_id, :run_id], name: :scans_unique_run_index)

    alter table(:scans) do
      remove :run_id
    end

    create unique_index(
             :scans,
             [
               :repository_id,
               :submitted_by_id,
               :commit_sha,
               :provenance,
               :review_kind,
               "COALESCE(model, '')",
               "COALESCE(prompt_version, '')"
             ],
             name: :scans_unique_submission_index
           )
  end
end
