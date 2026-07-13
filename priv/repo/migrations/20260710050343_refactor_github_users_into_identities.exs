defmodule Tarakan.Repo.Migrations.RefactorGithubUsersIntoIdentities do
  use Ecto.Migration

  def change do
    rename table(:users), to: table(:identities)
    rename table(:identities), :github_id, to: :provider_uid
    rename table(:identities), :github_login, to: :provider_login

    execute(
      "ALTER TABLE identities ALTER COLUMN provider_uid TYPE varchar USING provider_uid::varchar",
      "ALTER TABLE identities ALTER COLUMN provider_uid TYPE bigint USING provider_uid::bigint"
    )

    drop index(:identities, [:provider_uid], name: :users_github_id_index)
    drop index(:identities, [:provider_login], name: :users_github_login_index)

    alter table(:identities) do
      add :provider, :string, null: false, default: "github"
      add :account_id, references(:accounts, on_delete: :delete_all)
    end

    execute(
      """
      INSERT INTO accounts
        (handle, display_name, confirmed_at, reputation, inserted_at, updated_at)
      SELECT
        CASE
          WHEN char_length(lower(provider_login)) <= 32 THEN lower(provider_login)
          ELSE left(lower(provider_login), 20) || '-' || id::varchar
        END,
        name,
        date_trunc('second', now()),
        0,
        date_trunc('second', now()),
        date_trunc('second', now())
      FROM identities
      """,
      "SELECT 1"
    )

    execute(
      """
      UPDATE identities AS identity
      SET account_id = account.id
      FROM accounts AS account
      WHERE account.handle = CASE
        WHEN char_length(lower(identity.provider_login)) <= 32
          THEN lower(identity.provider_login)
        ELSE left(lower(identity.provider_login), 20) || '-' || identity.id::varchar
      END
      """,
      "SELECT 1"
    )

    execute(
      "ALTER TABLE identities ALTER COLUMN account_id SET NOT NULL",
      "ALTER TABLE identities ALTER COLUMN account_id DROP NOT NULL"
    )

    create unique_index(:identities, [:provider, :provider_uid])
    create unique_index(:identities, [:provider, :provider_login])
    create index(:identities, [:account_id])

    rename table(:repositories), :submitted_by_id, to: :submitted_by_identity_id

    execute(
      "ALTER TABLE repositories RENAME CONSTRAINT repositories_submitted_by_id_fkey TO repositories_submitted_by_identity_id_fkey",
      "ALTER TABLE repositories RENAME CONSTRAINT repositories_submitted_by_identity_id_fkey TO repositories_submitted_by_id_fkey"
    )

    drop index(:repositories, [:submitted_by_identity_id],
           name: :repositories_submitted_by_id_index
         )

    alter table(:repositories) do
      add :submitted_by_id, references(:accounts, on_delete: :nilify_all)
    end

    execute(
      """
      UPDATE repositories AS repository
      SET submitted_by_id = identity.account_id
      FROM identities AS identity
      WHERE repository.submitted_by_identity_id = identity.id
      """,
      "SELECT 1"
    )

    create index(:repositories, [:submitted_by_id])
    create index(:repositories, [:submitted_by_identity_id])
  end
end
