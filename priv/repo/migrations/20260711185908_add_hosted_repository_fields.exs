defmodule Tarakan.Repo.Migrations.AddHostedRepositoryFields do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :pushed_at, :utc_datetime_usec
      add :disk_size_bytes, :bigint, null: false, default: 0
    end

    # Audit history is append-only and must survive a hosted repository's
    # deletion; the event keeps subject_type/subject_id and its metadata.
    alter table(:audit_events) do
      modify :repository_id, references(:repositories, on_delete: :nilify_all),
        from: references(:repositories)
    end

    # The append-only trigger must allow exactly one mutation: the FK above
    # detaching repository_id when the referenced repository is deleted.
    # Every other column must be untouched or the write is still rejected.
    execute """
            CREATE OR REPLACE FUNCTION tarakan_prevent_audit_event_mutation()
            RETURNS trigger AS $$
            BEGIN
              IF TG_OP = 'UPDATE'
                 AND OLD.repository_id IS NOT NULL
                 AND NEW.repository_id IS NULL
                 AND ROW(NEW.id, NEW.actor_id, NEW.token_id, NEW.action, NEW.subject_type,
                         NEW.subject_id, NEW.from_state, NEW.to_state, NEW.reason_code,
                         NEW.request_id, NEW.client_version, NEW.metadata, NEW.inserted_at)
                     IS NOT DISTINCT FROM
                     ROW(OLD.id, OLD.actor_id, OLD.token_id, OLD.action, OLD.subject_type,
                         OLD.subject_id, OLD.from_state, OLD.to_state, OLD.reason_code,
                         OLD.request_id, OLD.client_version, OLD.metadata, OLD.inserted_at) THEN
                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'audit_events are append-only';
            END;
            $$ LANGUAGE plpgsql
            """,
            """
            CREATE OR REPLACE FUNCTION tarakan_prevent_audit_event_mutation()
            RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'audit_events are append-only';
            END;
            $$ LANGUAGE plpgsql
            """
  end
end
