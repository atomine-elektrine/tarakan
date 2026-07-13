defmodule Tarakan.Repo.Migrations.HardenModerationIntegrity do
  use Ecto.Migration

  def up do
    drop_if_exists index(:moderation_cases, [], name: :moderation_cases_one_open_report_index)

    create unique_index(
             :moderation_cases,
             [:reporter_id, :subject_type, :subject_id],
             where: "status IN ('open', 'in_review')",
             name: :moderation_cases_one_open_report_index
           )

    drop constraint(:moderation_cases, :moderation_cases_status_must_be_valid)

    create constraint(:moderation_cases, :moderation_cases_status_must_be_valid,
             check: "status IN ('open', 'in_review', 'resolved', 'dismissed', 'overturned')"
           )

    create constraint(
             :moderation_cases,
             :moderation_cases_resolution_state_must_be_consistent,
             check: """
             (
               status IN ('open', 'in_review')
               AND resolved_by_id IS NULL
               AND resolution IS NULL
               AND resolved_at IS NULL
             ) OR (
               status IN ('resolved', 'dismissed', 'overturned')
               AND resolved_by_id IS NOT NULL
               AND resolution IS NOT NULL
               AND resolved_at IS NOT NULL
             )
             """
           )

    create constraint(
             :moderation_cases,
             :moderation_cases_assignment_state_must_be_consistent,
             check: """
             (status = 'open' AND assigned_to_id IS NULL)
             OR (status <> 'open' AND assigned_to_id IS NOT NULL)
             """
           )

    drop constraint(:moderation_actions, :moderation_actions_action_must_be_valid)

    create constraint(:moderation_actions, :moderation_actions_action_must_be_valid,
             check: """
             action IN (
               'assign', 'quarantine', 'redact', 'restore', 'resolve', 'dismiss',
               'suspend_account', 'restore_account', 'appeal_upheld', 'appeal_denied'
             )
             """
           )

    create constraint(
             :moderation_appeals,
             :moderation_appeals_decision_state_must_be_consistent,
             check: """
             (
               status = 'open'
               AND decided_by_id IS NULL
               AND decision_reason IS NULL
               AND decided_at IS NULL
             ) OR (
               status IN ('upheld', 'denied')
               AND decided_by_id IS NOT NULL
               AND decision_reason IS NOT NULL
               AND decided_at IS NOT NULL
             )
             """
           )

    execute """
    ALTER TABLE moderation_cases
      DROP CONSTRAINT moderation_cases_repository_id_fkey
    """

    execute """
    ALTER TABLE moderation_cases
      ADD CONSTRAINT moderation_cases_repository_id_fkey
      FOREIGN KEY (repository_id) REFERENCES repositories(id) ON DELETE SET NULL
    """

    execute """
    CREATE FUNCTION tarakan_prevent_moderation_action_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'moderation_actions are append-only';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER moderation_actions_append_only
    BEFORE UPDATE OR DELETE ON moderation_actions
    FOR EACH ROW EXECUTE FUNCTION tarakan_prevent_moderation_action_mutation()
    """

    execute """
    CREATE FUNCTION tarakan_prevent_moderation_history_deletion()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'moderation history cannot be deleted';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER moderation_cases_preserve_history
    BEFORE DELETE ON moderation_cases
    FOR EACH ROW EXECUTE FUNCTION tarakan_prevent_moderation_history_deletion()
    """

    execute """
    CREATE TRIGGER moderation_appeals_preserve_history
    BEFORE DELETE ON moderation_appeals
    FOR EACH ROW EXECUTE FUNCTION tarakan_prevent_moderation_history_deletion()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS moderation_appeals_preserve_history ON moderation_appeals"
    execute "DROP TRIGGER IF EXISTS moderation_cases_preserve_history ON moderation_cases"
    execute "DROP FUNCTION IF EXISTS tarakan_prevent_moderation_history_deletion()"
    execute "DROP TRIGGER IF EXISTS moderation_actions_append_only ON moderation_actions"
    execute "DROP FUNCTION IF EXISTS tarakan_prevent_moderation_action_mutation()"

    execute "UPDATE moderation_cases SET status = 'resolved' WHERE status = 'overturned'"

    execute """
    DELETE FROM moderation_actions
    WHERE action IN ('appeal_upheld', 'appeal_denied')
    """

    execute """
    ALTER TABLE moderation_cases
      DROP CONSTRAINT moderation_cases_repository_id_fkey
    """

    execute """
    ALTER TABLE moderation_cases
      ADD CONSTRAINT moderation_cases_repository_id_fkey
      FOREIGN KEY (repository_id) REFERENCES repositories(id) ON DELETE CASCADE
    """

    drop constraint(
           :moderation_appeals,
           :moderation_appeals_decision_state_must_be_consistent
         )

    drop constraint(:moderation_actions, :moderation_actions_action_must_be_valid)

    create constraint(:moderation_actions, :moderation_actions_action_must_be_valid,
             check: """
             action IN (
               'assign', 'quarantine', 'redact', 'restore', 'resolve', 'dismiss',
               'suspend_account', 'restore_account'
             )
             """
           )

    drop constraint(:moderation_cases, :moderation_cases_assignment_state_must_be_consistent)
    drop constraint(:moderation_cases, :moderation_cases_resolution_state_must_be_consistent)
    drop constraint(:moderation_cases, :moderation_cases_status_must_be_valid)

    create constraint(:moderation_cases, :moderation_cases_status_must_be_valid,
             check: "status IN ('open', 'in_review', 'resolved', 'dismissed')"
           )

    drop_if_exists index(:moderation_cases, [], name: :moderation_cases_one_open_report_index)

    create unique_index(
             :moderation_cases,
             [:reporter_id, :subject_type, :subject_id, :reason],
             where: "status IN ('open', 'in_review')",
             name: :moderation_cases_one_open_report_index
           )
  end
end
