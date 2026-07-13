defmodule Tarakan.Repo.Migrations.CreateRepositories do
  use Ecto.Migration

  def change do
    create table(:repositories) do
      add :host, :string, null: false, default: "github.com"
      add :owner, :string, null: false
      add :name, :string, null: false
      add :canonical_url, :string, null: false
      add :status, :string, null: false, default: "unscanned"
      add :scan_count, :integer, null: false, default: 0
      add :open_findings_count, :integer, null: false, default: 0
      add :verified_findings_count, :integer, null: false, default: 0
      add :last_scanned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repositories, [:host, :owner, :name])
    create index(:repositories, [:status])
    create index(:repositories, [:last_scanned_at])

    create constraint(:repositories, :repositories_status_must_be_valid,
             check: "status IN ('unscanned', 'scanning', 'findings', 'clear', 'stale')"
           )
  end
end
