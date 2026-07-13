defmodule Tarakan.Repo.Migrations.AddPublicIdsToScanFindings do
  use Ecto.Migration

  def change do
    alter table(:scan_findings) do
      add :public_id, :uuid, null: false, default: fragment("gen_random_uuid()")
    end

    create unique_index(:scan_findings, [:public_id])
  end
end
