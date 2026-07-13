defmodule Tarakan.Repo.Migrations.CreateRegistryShouts do
  use Ecto.Migration

  def change do
    create table(:registry_shouts) do
      add :body, :string, null: false, size: 280
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :removed_at, :utc_datetime_usec
      add :removed_reason, :string, size: 100
      add :removed_by_id, references(:accounts, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:registry_shouts, [:inserted_at, :id])
    create index(:registry_shouts, [:account_id])
  end
end
