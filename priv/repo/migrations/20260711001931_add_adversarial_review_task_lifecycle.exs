defmodule Tarakan.Repo.Migrations.AddAdversarialReviewTaskLifecycle do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE review_tasks DROP CONSTRAINT IF EXISTS review_tasks_status_must_be_valid"
    )

    alter table(:review_tasks) do
      modify :status, :string, default: "proposed", from: {:string, default: "open"}
      add :published_at, :utc_datetime_usec
      add :submitted_at, :utc_datetime_usec
      add :reviewed_at, :utc_datetime_usec
      add :reviewed_by_id, references(:accounts, on_delete: :restrict)
    end

    execute("""
    UPDATE review_tasks
    SET published_at = inserted_at,
        submitted_at = CASE WHEN status = 'completed' THEN completed_at ELSE NULL END,
        reviewed_at = CASE WHEN status = 'completed' THEN completed_at ELSE NULL END,
        status = CASE WHEN status = 'completed' THEN 'accepted' ELSE status END
    """)

    create constraint(:review_tasks, :review_tasks_status_must_be_valid,
             check:
               "status IN ('proposed', 'open', 'claimed', 'submitted', 'accepted', 'changes_requested', 'rejected', 'cancelled')"
           )

    create index(:review_tasks, [:reviewed_by_id])
    create index(:review_tasks, [:repository_id, :created_by_id, :status])
    create index(:review_tasks, [:repository_id, :claimed_by_id, :status])

    drop_if_exists unique_index(:review_task_contributions, [:review_task_id])

    alter table(:review_task_contributions) do
      add :version, :integer, null: false, default: 1
    end

    execute("""
    UPDATE review_task_contributions
    SET evidence = 'Legacy contribution did not include separate reproduction evidence.'
    WHERE evidence IS NULL OR btrim(evidence) = ''
    """)

    alter table(:review_task_contributions) do
      modify :evidence, :text, null: false, from: :text
    end

    create unique_index(:review_task_contributions, [:review_task_id, :version])

    alter table(:review_tasks) do
      add :latest_contribution_id,
          references(:review_task_contributions, on_delete: :nilify_all)
    end

    execute("""
    UPDATE review_tasks AS task
    SET latest_contribution_id = contribution.id
    FROM review_task_contributions AS contribution
    WHERE contribution.review_task_id = task.id
    """)

    create index(:review_tasks, [:latest_contribution_id])

    create table(:review_task_decisions) do
      add :review_task_id, references(:review_tasks, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :action, :string, null: false
      add :reason, :text, null: false
      add :evidence, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:review_task_decisions, [:review_task_id, "inserted_at DESC"])
    create index(:review_task_decisions, [:account_id])

    create constraint(:review_task_decisions, :review_task_decisions_action_must_be_valid,
             check: "action IN ('publish', 'accept', 'request_changes', 'reject', 'cancel')"
           )
  end

  def down do
    drop table(:review_task_decisions)

    alter table(:review_tasks) do
      remove :latest_contribution_id
    end

    drop unique_index(:review_task_contributions, [:review_task_id, :version])

    alter table(:review_task_contributions) do
      remove :version
      modify :evidence, :text, null: true, from: {:text, null: false}
    end

    create unique_index(:review_task_contributions, [:review_task_id])

    drop constraint(:review_tasks, :review_tasks_status_must_be_valid)

    execute("UPDATE review_tasks SET status = 'completed' WHERE status = 'accepted'")

    execute(
      "UPDATE review_tasks SET status = 'open' WHERE status NOT IN ('open', 'claimed', 'completed')"
    )

    alter table(:review_tasks) do
      remove :reviewed_by_id
      remove :reviewed_at
      remove :submitted_at
      remove :published_at
      modify :status, :string, default: "open", from: {:string, default: "proposed"}
    end

    create constraint(:review_tasks, :review_tasks_status_must_be_valid,
             check: "status IN ('open', 'claimed', 'completed')"
           )
  end
end
