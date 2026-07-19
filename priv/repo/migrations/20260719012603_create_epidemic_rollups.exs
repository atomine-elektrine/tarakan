defmodule Tarakan.Repo.Migrations.CreateEpidemicRollups do
  use Ecto.Migration

  def change do
    create table(:epidemic_patterns, primary_key: false) do
      add :pattern_key, :string, size: 64, primary_key: true
      add :title, :string, null: false
      add :severity, :string
      add :sample_file_path, :string
      add :sample_occurrence_public_id, :binary_id

      add :repo_count, :integer, null: false, default: 0
      add :instance_count, :integer, null: false, default: 0
      add :open_count, :integer, null: false, default: 0
      add :verified_count, :integer, null: false, default: 0
      add :fixed_count, :integer, null: false, default: 0
      add :disputed_count, :integer, null: false, default: 0

      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec

      # Windowed aggregates for 7 / 30 / 90 / 365 day list semantics
      add :repo_count_7d, :integer, null: false, default: 0
      add :instance_count_7d, :integer, null: false, default: 0
      add :open_count_7d, :integer, null: false, default: 0
      add :verified_count_7d, :integer, null: false, default: 0
      add :fixed_count_7d, :integer, null: false, default: 0
      add :disputed_count_7d, :integer, null: false, default: 0
      add :last_seen_at_7d, :utc_datetime_usec

      add :repo_count_30d, :integer, null: false, default: 0
      add :instance_count_30d, :integer, null: false, default: 0
      add :open_count_30d, :integer, null: false, default: 0
      add :verified_count_30d, :integer, null: false, default: 0
      add :fixed_count_30d, :integer, null: false, default: 0
      add :disputed_count_30d, :integer, null: false, default: 0
      add :last_seen_at_30d, :utc_datetime_usec

      add :repo_count_90d, :integer, null: false, default: 0
      add :instance_count_90d, :integer, null: false, default: 0
      add :open_count_90d, :integer, null: false, default: 0
      add :verified_count_90d, :integer, null: false, default: 0
      add :fixed_count_90d, :integer, null: false, default: 0
      add :disputed_count_90d, :integer, null: false, default: 0
      add :last_seen_at_90d, :utc_datetime_usec

      add :repo_count_365d, :integer, null: false, default: 0
      add :instance_count_365d, :integer, null: false, default: 0
      add :open_count_365d, :integer, null: false, default: 0
      add :verified_count_365d, :integer, null: false, default: 0
      add :fixed_count_365d, :integer, null: false, default: 0
      add :disputed_count_365d, :integer, null: false, default: 0
      add :last_seen_at_365d, :utc_datetime_usec

      add :refreshed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:epidemic_patterns, [:repo_count_7d, :last_seen_at_7d],
             name: :epidemic_patterns_rank_7d_idx,
             where: "repo_count_7d >= 2"
           )

    create index(:epidemic_patterns, [:repo_count_30d, :last_seen_at_30d],
             name: :epidemic_patterns_rank_30d_idx,
             where: "repo_count_30d >= 2"
           )

    create index(:epidemic_patterns, [:repo_count_90d, :last_seen_at_90d],
             name: :epidemic_patterns_rank_90d_idx,
             where: "repo_count_90d >= 2"
           )

    create index(:epidemic_patterns, [:repo_count_365d, :last_seen_at_365d],
             name: :epidemic_patterns_rank_365d_idx,
             where: "repo_count_365d >= 2"
           )

    create table(:epidemic_pattern_repos, primary_key: false) do
      add :pattern_key, :string, size: 64, primary_key: true

      add :repository_id, references(:repositories, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :instance_count, :integer, null: false, default: 0
      add :open_count, :integer, null: false, default: 0
      add :verified_count, :integer, null: false, default: 0
      add :fixed_count, :integer, null: false, default: 0
      add :disputed_count, :integer, null: false, default: 0
      add :primary_status, :string, null: false, default: "open"
      add :severity, :string
      add :title, :string
      add :sample_occurrence_public_id, :binary_id
      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:epidemic_pattern_repos, [:repository_id])

    create index(:epidemic_pattern_repos, [:pattern_key, :last_seen_at, :repository_id],
             name: :epidemic_pattern_repos_pattern_recent_idx
           )

    create table(:epidemic_pattern_instances, primary_key: false) do
      add :canonical_finding_id, references(:canonical_findings, on_delete: :delete_all),
        primary_key: true

      add :pattern_key, :string, size: 64, null: false

      add :repository_id, references(:repositories, on_delete: :delete_all), null: false

      add :status, :string, null: false
      add :severity, :string
      add :title, :string, null: false
      add :file_path, :string
      add :sample_occurrence_public_id, :binary_id
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:epidemic_pattern_instances, [:pattern_key, :canonical_finding_id])
    create index(:epidemic_pattern_instances, [:pattern_key, :updated_at])
    create index(:epidemic_pattern_instances, [:status, :updated_at, :pattern_key])
    create index(:epidemic_pattern_instances, [:repository_id])

    # Supporting source indexes (non-concurrent; fine for current table sizes)
    create index(:canonical_findings, [:pattern_key, :repository_id],
             name: :canonical_findings_pattern_repo_idx,
             where: "pattern_key IS NOT NULL AND pattern_key <> ''"
           )

    create index(:canonical_findings, [:pattern_key, :status],
             name: :canonical_findings_pattern_status_idx,
             where: "pattern_key IS NOT NULL AND pattern_key <> ''"
           )

    create index(:canonical_findings, [:pattern_key, :updated_at],
             name: :canonical_findings_pattern_updated_idx,
             where: "pattern_key IS NOT NULL AND pattern_key <> ''"
           )

    create index(:repositories, [:id],
             name: :repositories_listed_id_idx,
             where: "listing_status = 'listed'"
           )

    create index(:scans, [:repository_id, :id],
             name: :scans_public_repo_idx,
             where: "visibility = 'public'"
           )
  end
end
