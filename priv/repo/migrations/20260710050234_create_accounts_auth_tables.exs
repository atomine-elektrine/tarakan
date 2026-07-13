defmodule Tarakan.Repo.Migrations.CreateAccountsAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:accounts) do
      add :handle, :citext, null: false
      add :display_name, :string
      add :email, :citext
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      add :reputation, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:accounts, [:handle])
    create unique_index(:accounts, [:email], where: "email IS NOT NULL")

    create table(:accounts_tokens) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:accounts_tokens, [:account_id])
    create unique_index(:accounts_tokens, [:context, :token])
  end
end
