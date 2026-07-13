defmodule Tarakan.Repo.Migrations.AddAuthorizationFoundations do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :state, :string, null: false, default: "probation"
      add :platform_role, :string, null: false, default: "member"
      add :trust_tier, :string, null: false, default: "new"
    end

    create constraint(:accounts, :accounts_state_must_be_valid,
             check: "state IN ('probation', 'active', 'restricted', 'suspended', 'banned')"
           )

    create constraint(:accounts, :accounts_platform_role_must_be_valid,
             check: "platform_role IN ('member', 'moderator', 'admin')"
           )

    create constraint(:accounts, :accounts_trust_tier_must_be_valid,
             check: "trust_tier IN ('new', 'contributor', 'reviewer')"
           )

    create index(:accounts, [:state])
    create index(:accounts, [:platform_role])
    create index(:accounts, [:trust_tier])

    alter table(:repositories) do
      add :participation_mode, :string, null: false, default: "unclaimed"
    end

    create constraint(:repositories, :repositories_participation_mode_must_be_valid,
             check:
               "participation_mode IN ('unclaimed', 'community', 'maintainer_verified', 'curated', 'paused')"
           )

    create index(:repositories, [:participation_mode])

    create table(:repository_memberships) do
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :verified_at, :utc_datetime_usec
      add :verified_by_account_id, references(:accounts)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_memberships, [:repository_id, :account_id])
    create index(:repository_memberships, [:account_id, :status])
    create index(:repository_memberships, [:repository_id, :status, :role])

    create constraint(:repository_memberships, :repository_memberships_role_must_be_valid,
             check: "role IN ('steward', 'reviewer')"
           )

    create constraint(:repository_memberships, :repository_memberships_status_must_be_valid,
             check: "status IN ('verified', 'pending', 'revoked')"
           )

    create constraint(
             :repository_memberships,
             :repository_memberships_verified_state_must_be_consistent,
             check:
               "(status = 'verified' AND verified_at IS NOT NULL) OR (status <> 'verified' AND verified_at IS NULL)"
           )

    create table(:audit_events) do
      add :actor_id, references(:accounts)
      add :token_id, :bigint
      add :action, :string, null: false
      add :subject_type, :string
      add :subject_id, :bigint
      add :repository_id, references(:repositories)
      add :from_state, :string
      add :to_state, :string
      add :reason_code, :string
      add :request_id, :string
      add :client_version, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:actor_id, :inserted_at])
    create index(:audit_events, [:repository_id, :inserted_at])
    create index(:audit_events, [:subject_type, :subject_id, :inserted_at])
    create index(:audit_events, [:request_id])

    execute """
            CREATE FUNCTION tarakan_prevent_audit_event_mutation()
            RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'audit_events are append-only';
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION IF EXISTS tarakan_prevent_audit_event_mutation()"

    execute """
            CREATE TRIGGER audit_events_append_only
            BEFORE UPDATE OR DELETE ON audit_events
            FOR EACH ROW EXECUTE FUNCTION tarakan_prevent_audit_event_mutation()
            """,
            "DROP TRIGGER IF EXISTS audit_events_append_only ON audit_events"
  end
end
