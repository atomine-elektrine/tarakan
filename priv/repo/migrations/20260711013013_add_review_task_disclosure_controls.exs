defmodule Tarakan.Repo.Migrations.AddReviewTaskDisclosureControls do
  use Ecto.Migration

  def up do
    alter table(:review_tasks) do
      add :visibility, :string, null: false, default: "restricted"
      add :disclosed_at, :utc_datetime_usec
      add :disclosed_by_id, references(:accounts, on_delete: :restrict)
      add :sensitive_data_reviewed_at, :utc_datetime_usec
      add :sensitive_data_reviewed_by_id, references(:accounts, on_delete: :restrict)
    end

    # Keep existing queue entries discoverable, but quarantine every legacy
    # accepted result until a new, attributable disclosure decision is made.
    execute("""
    UPDATE review_tasks
    SET visibility = CASE
      WHEN status IN ('open', 'claimed') AND EXISTS (
        SELECT 1 FROM review_task_decisions
        WHERE review_task_id = review_tasks.id AND action = 'publish'
      ) THEN 'public_summary'
      ELSE 'restricted'
    END,
    disclosed_at = CASE
      WHEN status IN ('open', 'claimed') AND EXISTS (
        SELECT 1 FROM review_task_decisions
        WHERE review_task_id = review_tasks.id AND action = 'publish'
      ) THEN published_at
      ELSE NULL
    END,
    disclosed_by_id = CASE
      WHEN status IN ('open', 'claimed') AND EXISTS (
        SELECT 1 FROM review_task_decisions
        WHERE review_task_id = review_tasks.id AND action = 'publish'
      ) THEN (
        SELECT account_id
        FROM review_task_decisions
        WHERE review_task_id = review_tasks.id AND action = 'publish'
        ORDER BY inserted_at DESC, id DESC
        LIMIT 1
      )
      ELSE NULL
    END
    """)

    create index(:review_tasks, [:repository_id, :status, :visibility])
    create index(:review_tasks, [:disclosed_by_id])
    create index(:review_tasks, [:sensitive_data_reviewed_by_id])

    create constraint(:review_tasks, :review_tasks_visibility_must_be_valid,
             check: "visibility IN ('restricted', 'public_summary', 'public')"
           )

    create constraint(:review_tasks, :review_tasks_visibility_must_match_state,
             check:
               "visibility = 'restricted' OR " <>
                 "(visibility = 'public_summary' AND status IN ('open', 'claimed', 'accepted')) OR " <>
                 "(visibility = 'public' AND status = 'accepted')"
           )

    create constraint(:review_tasks, :review_tasks_disclosure_must_be_attributed,
             check:
               "visibility = 'restricted' OR (disclosed_at IS NOT NULL AND disclosed_by_id IS NOT NULL)"
           )

    create constraint(:review_tasks, :review_tasks_full_disclosure_requires_sensitive_review,
             check:
               "visibility != 'public' OR " <>
                 "(sensitive_data_reviewed_at IS NOT NULL AND sensitive_data_reviewed_by_id IS NOT NULL)"
           )

    drop constraint(:review_task_decisions, :review_task_decisions_action_must_be_valid)

    create constraint(:review_task_decisions, :review_task_decisions_action_must_be_valid,
             check:
               "action IN ('publish', 'accept', 'request_changes', 'reject', 'cancel', 'disclose')"
           )
  end

  def down do
    drop constraint(:review_task_decisions, :review_task_decisions_action_must_be_valid)

    create constraint(:review_task_decisions, :review_task_decisions_action_must_be_valid,
             check: "action IN ('publish', 'accept', 'request_changes', 'reject', 'cancel')"
           )

    drop constraint(
           :review_tasks,
           :review_tasks_full_disclosure_requires_sensitive_review
         )

    drop constraint(:review_tasks, :review_tasks_disclosure_must_be_attributed)
    drop constraint(:review_tasks, :review_tasks_visibility_must_match_state)
    drop constraint(:review_tasks, :review_tasks_visibility_must_be_valid)

    alter table(:review_tasks) do
      remove :sensitive_data_reviewed_by_id
      remove :sensitive_data_reviewed_at
      remove :disclosed_by_id
      remove :disclosed_at
      remove :visibility
    end
  end
end
