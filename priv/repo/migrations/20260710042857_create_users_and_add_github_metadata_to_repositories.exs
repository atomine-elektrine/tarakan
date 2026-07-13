defmodule Tarakan.Repo.Migrations.CreateUsersAndAddGithubMetadataToRepositories do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :github_id, :bigint, null: false
      add :github_login, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :profile_url, :string, null: false
      add :last_login_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:github_id])
    create unique_index(:users, [:github_login])

    alter table(:repositories) do
      add :github_id, :bigint
      add :default_branch, :string
      add :description, :text
      add :primary_language, :string
      add :stars_count, :integer, null: false, default: 0
      add :forks_count, :integer, null: false, default: 0
      add :archived, :boolean, null: false, default: false
      add :last_synced_at, :utc_datetime_usec
      add :submitted_by_id, references(:users, on_delete: :nilify_all)
    end

    create unique_index(:repositories, [:github_id], where: "github_id IS NOT NULL")
    create index(:repositories, [:submitted_by_id])
  end
end
