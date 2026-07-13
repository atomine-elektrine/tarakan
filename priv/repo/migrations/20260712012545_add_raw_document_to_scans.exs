defmodule Tarakan.Repo.Migrations.AddRawDocumentToScans do
  use Ecto.Migration

  def change do
    alter table(:scans) do
      # The Tarakan Scan Format document exactly as the harness submitted it.
      # Findings are parsed into scan_findings rows for querying; this keeps
      # the model's raw report on the record for human review.
      add :raw_document, :text
    end
  end
end
