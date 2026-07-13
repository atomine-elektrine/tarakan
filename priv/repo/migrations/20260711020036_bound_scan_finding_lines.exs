defmodule Tarakan.Repo.Migrations.BoundScanFindingLines do
  use Ecto.Migration

  def up do
    drop constraint(:scan_findings, :scan_findings_lines_must_be_ordered)

    create constraint(:scan_findings, :scan_findings_lines_must_be_ordered,
             check:
               "(line_start IS NULL AND line_end IS NULL) OR " <>
                 "(line_start BETWEEN 1 AND 1000000 AND " <>
                 "line_end BETWEEN line_start AND 1000000)"
           )
  end

  def down do
    drop constraint(:scan_findings, :scan_findings_lines_must_be_ordered)

    create constraint(:scan_findings, :scan_findings_lines_must_be_ordered,
             check:
               "(line_start IS NULL) OR " <>
                 "(line_start >= 1 AND (line_end IS NULL OR line_end >= line_start))"
           )
  end
end
