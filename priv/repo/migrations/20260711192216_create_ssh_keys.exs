defmodule Tarakan.Repo.Migrations.CreateSshKeys do
  use Ecto.Migration

  def change do
    create table(:ssh_keys) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key_type, :string, null: false
      add :public_key, :text, null: false
      add :fingerprint_sha256, :string, null: false
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Global uniqueness is load-bearing: SSH authentication resolves a
    # presented key to exactly one account by fingerprint.
    create unique_index(:ssh_keys, [:fingerprint_sha256])
    create index(:ssh_keys, [:account_id])
  end
end
