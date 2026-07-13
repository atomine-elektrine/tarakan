defmodule Tarakan.Repo.Migrations.AddRepositoryListingStatus do
  use Ecto.Migration

  def up do
    alter table(:repositories) do
      add :listing_status, :string, null: false, default: "pending"
    end

    execute "UPDATE repositories SET listing_status = 'listed'"

    create constraint(:repositories, :repositories_listing_status_must_be_valid,
             check: "listing_status IN ('pending', 'listed', 'quarantined')"
           )

    create index(:repositories, [:listing_status, :inserted_at])
  end

  def down do
    alter table(:repositories) do
      remove :listing_status
    end
  end
end
