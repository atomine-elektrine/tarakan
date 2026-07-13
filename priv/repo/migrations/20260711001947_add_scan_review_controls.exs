defmodule Tarakan.Repo.Migrations.AddScanReviewControls do
  use Ecto.Migration

  def up do
    alter table(:scans) do
      add :review_status, :string, null: false, default: "quarantined"
      add :visibility, :string, null: false, default: "restricted"
      add :moderation_reason, :string
      add :moderation_notes, :text
      add :reviewed_at, :utc_datetime_usec

      add :reviewed_by_id, references(:accounts, on_delete: :restrict)
    end

    create index(:scans, [:repository_id, :review_status, :visibility, "inserted_at DESC"],
             name: :scans_public_record_index
           )

    create index(:scans, [:reviewed_by_id])

    create constraint(:scans, :scans_review_status_must_be_valid,
             check: "review_status IN ('quarantined', 'accepted', 'rejected', 'contested')"
           )

    create constraint(:scans, :scans_visibility_must_be_valid,
             check: "visibility IN ('restricted', 'public_summary', 'public')"
           )

    create constraint(:scans, :scans_publication_requires_acceptance,
             check: "visibility = 'restricted' OR review_status = 'accepted'"
           )

    create constraint(:scans, :scans_acceptance_requires_verification,
             check: "review_status != 'accepted' OR verified_at IS NOT NULL"
           )

    create constraint(:scans, :scans_acceptance_requires_quorum,
             check: "review_status != 'accepted' OR confirmations_count - disputes_count >= 2"
           )

    create constraint(:scans, :scans_moderation_requires_attribution,
             check:
               "review_status = 'quarantined' OR (reviewed_by_id IS NOT NULL AND reviewed_at IS NOT NULL AND length(btrim(moderation_reason)) >= 3 AND length(btrim(moderation_notes)) >= 20)"
           )

    execute "UPDATE repositories SET status = 'unscanned' WHERE status = 'clear'"
    drop constraint(:repositories, :repositories_status_must_be_valid)

    create constraint(:repositories, :repositories_status_must_be_valid,
             check: "status IN ('unscanned', 'scanning', 'findings', 'reviewed', 'stale')"
           )
  end

  def down do
    execute "UPDATE repositories SET status = 'unscanned' WHERE status = 'reviewed'"
    drop constraint(:repositories, :repositories_status_must_be_valid)

    create constraint(:repositories, :repositories_status_must_be_valid,
             check: "status IN ('unscanned', 'scanning', 'findings', 'clear', 'stale')"
           )

    drop constraint(:scans, :scans_moderation_requires_attribution)
    drop constraint(:scans, :scans_acceptance_requires_quorum)
    drop constraint(:scans, :scans_acceptance_requires_verification)
    drop constraint(:scans, :scans_publication_requires_acceptance)
    drop constraint(:scans, :scans_visibility_must_be_valid)
    drop constraint(:scans, :scans_review_status_must_be_valid)
    drop index(:scans, [:reviewed_by_id])
    drop index(:scans, name: :scans_public_record_index)

    alter table(:scans) do
      remove :reviewed_by_id
      remove :reviewed_at
      remove :moderation_notes
      remove :moderation_reason
      remove :visibility
      remove :review_status
    end
  end
end
