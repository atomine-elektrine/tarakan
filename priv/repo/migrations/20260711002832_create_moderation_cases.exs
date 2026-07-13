defmodule Tarakan.Repo.Migrations.CreateModerationCases do
  use Ecto.Migration

  def change do
    create table(:moderation_cases) do
      add :reporter_id, references(:accounts, on_delete: :restrict), null: false
      add :subject_owner_id, references(:accounts, on_delete: :nilify_all)
      add :repository_id, references(:repositories, on_delete: :delete_all)
      add :subject_type, :string, null: false
      add :subject_id, :bigint, null: false
      add :reason, :string, null: false
      add :description, :text, null: false
      add :status, :string, null: false, default: "open"
      add :assigned_to_id, references(:accounts, on_delete: :nilify_all)
      add :resolved_by_id, references(:accounts, on_delete: :restrict)
      add :resolution, :text
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:moderation_cases, [:status, "inserted_at ASC"])
    create index(:moderation_cases, [:repository_id, :status])
    create index(:moderation_cases, [:subject_type, :subject_id])
    create index(:moderation_cases, [:reporter_id, :inserted_at])
    create index(:moderation_cases, [:subject_owner_id])

    create unique_index(
             :moderation_cases,
             [:reporter_id, :subject_type, :subject_id, :reason],
             where: "status IN ('open', 'in_review')",
             name: :moderation_cases_one_open_report_index
           )

    create constraint(:moderation_cases, :moderation_cases_subject_type_must_be_valid,
             check:
               "subject_type IN ('repository', 'account', 'scan', 'finding', 'review_task', 'contribution')"
           )

    create constraint(:moderation_cases, :moderation_cases_reason_must_be_valid,
             check:
               "reason IN ('spam', 'unsafe_disclosure', 'harassment', 'plagiarism', 'malicious_instructions', 'fabricated_evidence', 'secrets_or_pii', 'other')"
           )

    create constraint(:moderation_cases, :moderation_cases_status_must_be_valid,
             check: "status IN ('open', 'in_review', 'resolved', 'dismissed')"
           )

    create table(:moderation_actions) do
      add :moderation_case_id, references(:moderation_cases, on_delete: :delete_all), null: false
      add :actor_id, references(:accounts, on_delete: :restrict), null: false
      add :action, :string, null: false
      add :reason, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:moderation_actions, [:moderation_case_id, "inserted_at ASC"])
    create index(:moderation_actions, [:actor_id])

    create constraint(:moderation_actions, :moderation_actions_action_must_be_valid,
             check:
               "action IN ('assign', 'quarantine', 'redact', 'restore', 'resolve', 'dismiss', 'suspend_account', 'restore_account')"
           )

    create table(:moderation_appeals) do
      add :moderation_case_id, references(:moderation_cases, on_delete: :delete_all), null: false
      add :appellant_id, references(:accounts, on_delete: :restrict), null: false
      add :reason, :text, null: false
      add :status, :string, null: false, default: "open"
      add :decided_by_id, references(:accounts, on_delete: :restrict)
      add :decision_reason, :text
      add :decided_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:moderation_appeals, [:moderation_case_id, :appellant_id])
    create index(:moderation_appeals, [:status, "inserted_at ASC"])

    create constraint(:moderation_appeals, :moderation_appeals_status_must_be_valid,
             check: "status IN ('open', 'upheld', 'denied')"
           )
  end
end
