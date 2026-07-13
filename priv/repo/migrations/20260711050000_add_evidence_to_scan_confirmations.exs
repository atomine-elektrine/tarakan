defmodule Tarakan.Repo.Migrations.AddEvidenceToScanConfirmations do
  use Ecto.Migration

  def change do
    alter table(:scan_confirmations) do
      add :evidence, :text
    end
  end
end
