defmodule Tarakan.Repo.Migrations.CreateReviewTasks do
  use Ecto.Migration

  def change do
    create table(:review_tasks) do
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :created_by_id, references(:accounts, on_delete: :restrict), null: false
      add :claimed_by_id, references(:accounts, on_delete: :restrict)
      add :commit_sha, :string, null: false
      add :commit_committed_at, :utc_datetime_usec
      add :kind, :string, null: false
      add :capability, :string, null: false, default: "human"
      add :title, :string, null: false
      add :description, :text, null: false
      add :status, :string, null: false, default: "open"
      add :claimed_at, :utc_datetime_usec
      add :claim_expires_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_tasks, [:repository_id, :status, "inserted_at DESC"])
    create index(:review_tasks, [:created_by_id])
    create index(:review_tasks, [:claimed_by_id])

    create constraint(:review_tasks, :review_tasks_commit_sha_must_be_full_sha,
             check: "commit_sha ~ '^[0-9a-f]{40}$'"
           )

    create constraint(:review_tasks, :review_tasks_kind_must_be_valid,
             check:
               "kind IN ('code_review', 'threat_model', 'privacy_review', 'business_logic', 'verify_findings', 'write_fix')"
           )

    create constraint(:review_tasks, :review_tasks_capability_must_be_valid,
             check: "capability IN ('human', 'agent', 'hybrid')"
           )

    create constraint(:review_tasks, :review_tasks_status_must_be_valid,
             check: "status IN ('open', 'claimed', 'completed')"
           )

    create table(:review_task_contributions) do
      add :review_task_id, references(:review_tasks, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :provenance, :string, null: false
      add :summary, :text, null: false
      add :evidence, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:review_task_contributions, [:review_task_id])
    create index(:review_task_contributions, [:account_id])

    create constraint(
             :review_task_contributions,
             :review_task_contributions_provenance_must_be_valid,
             check: "provenance IN ('human', 'agent', 'hybrid')"
           )
  end
end
