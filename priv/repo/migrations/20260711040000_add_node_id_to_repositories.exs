defmodule Tarakan.Repo.Migrations.AddNodeIdToRepositories do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :node_id, :string
    end

    create unique_index(:repositories, [:node_id], where: "node_id IS NOT NULL")
  end
end
