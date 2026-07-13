defmodule Tarakan.Repo.Migrations.CreateApiCredentials do
  use Ecto.Migration

  def change do
    create table(:api_credentials) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :repository_id, references(:repositories, on_delete: :delete_all)
      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :token_prefix, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_credentials, [:token_hash])
    create index(:api_credentials, [:account_id, :revoked_at])
    create index(:api_credentials, [:repository_id])
    create index(:api_credentials, [:expires_at])

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid,
             check:
               "scopes <@ ARRAY['tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit']::varchar[]"
           )
  end
end
