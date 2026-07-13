defmodule Tarakan.Repo.Migrations.CreateScans do
  use Ecto.Migration

  def change do
    create table(:scans) do
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :submitted_by_id, references(:accounts, on_delete: :restrict), null: false
      add :commit_sha, :string, null: false
      add :commit_committed_at, :utc_datetime_usec
      add :model, :string, null: false
      add :prompt_version, :string, null: false
      add :notes, :text
      add :findings_count, :integer, null: false, default: 0
      add :confirmations_count, :integer, null: false, default: 0
      add :disputes_count, :integer, null: false, default: 0
      add :verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scans, [:repository_id, "inserted_at DESC"])
    create index(:scans, [:submitted_by_id])

    create unique_index(
             :scans,
             [:repository_id, :submitted_by_id, :commit_sha, :model, :prompt_version],
             name: :scans_unique_submission_index
           )

    create constraint(:scans, :scans_commit_sha_must_be_full_sha,
             check: "commit_sha ~ '^[0-9a-f]{40}$'"
           )

    create constraint(:scans, :scans_counts_must_be_nonnegative,
             check: "findings_count >= 0 AND confirmations_count >= 0 AND disputes_count >= 0"
           )

    create table(:scan_findings) do
      add :scan_id, references(:scans, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
      add :file_path, :string, null: false, size: 500
      add :line_start, :integer
      add :line_end, :integer
      add :severity, :string, null: false
      add :title, :string, null: false
      add :description, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scan_findings, [:scan_id])

    create constraint(:scan_findings, :scan_findings_severity_must_be_valid,
             check: "severity IN ('critical', 'high', 'medium', 'low', 'info')"
           )

    create constraint(:scan_findings, :scan_findings_lines_must_be_ordered,
             check:
               "(line_start IS NULL) OR (line_start >= 1 AND (line_end IS NULL OR line_end >= line_start))"
           )

    create table(:scan_confirmations) do
      add :scan_id, references(:scans, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :verdict, :string, null: false
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scan_confirmations, [:scan_id, :account_id])
    create index(:scan_confirmations, [:account_id])

    create constraint(:scan_confirmations, :scan_confirmations_verdict_must_be_valid,
             check: "verdict IN ('confirmed', 'disputed')"
           )
  end
end
