defmodule Tarakan.Repo.Migrations.AddReviewProvenance do
  use Ecto.Migration

  def change do
    drop_if_exists index(
                     :scans,
                     [:repository_id, :submitted_by_id, :commit_sha, :model, :prompt_version],
                     name: :scans_unique_submission_index
                   )

    alter table(:scans) do
      add :provenance, :string, null: false, default: "agent"
      add :review_kind, :string, null: false, default: "code_review"
      modify :model, :string, null: true, from: {:string, null: false}
      modify :prompt_version, :string, null: true, from: {:string, null: false}
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

    create constraint(:scans, :scans_provenance_must_be_valid,
             check: "provenance IN ('agent', 'human', 'hybrid')"
           )

    create constraint(:scans, :scans_review_kind_must_be_valid,
             check:
               "review_kind IN ('code_review', 'threat_model', 'privacy_review', 'business_logic')"
           )

    alter table(:scan_confirmations) do
      add :provenance, :string, null: false, default: "human"
    end

    create constraint(:scan_confirmations, :scan_confirmations_provenance_must_be_valid,
             check: "provenance IN ('agent', 'human', 'hybrid')"
           )
  end
end
