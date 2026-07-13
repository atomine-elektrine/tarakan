defmodule Tarakan.Repo.Migrations.CreateClientAuthorizations do
  use Ecto.Migration

  def change do
    create table(:client_authorizations) do
      add :device_code_hash, :binary, null: false
      add :user_code, :string, null: false
      add :client_name, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec

      add :account_id, references(:accounts, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:client_authorizations, [:device_code_hash])
    create unique_index(:client_authorizations, [:user_code])
    create index(:client_authorizations, [:expires_at])

    create constraint(:client_authorizations, :client_authorizations_status_must_be_valid,
             check: "status IN ('pending', 'approved', 'denied', 'consumed', 'expired')"
           )
  end
end
