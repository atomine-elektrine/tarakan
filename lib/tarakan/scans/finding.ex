defmodule Tarakan.Scans.Finding do
  @moduledoc """
  A single finding reported by a contributed scan.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Scans.ScanFormat
  alias Tarakan.RepositoryPath

  schema "scan_findings" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :position, :integer, default: 0
    field :file_path, :string
    field :line_start, :integer
    field :line_end, :integer
    field :severity, :string
    field :title, :string
    field :description, :string
    field :fingerprint, :string
    field :disposition, :string, default: "new"
    field :claimed_canonical_public_id, Ecto.UUID

    belongs_to :scan, Tarakan.Scans.Scan
    belongs_to :canonical_finding, Tarakan.Scans.CanonicalFinding

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [
      :position,
      :file_path,
      :line_start,
      :line_end,
      :severity,
      :title,
      :description,
      :disposition,
      :claimed_canonical_public_id
    ])
    |> validate_required([:file_path, :severity, :title, :description])
    |> validate_inclusion(:severity, ScanFormat.severities())
    |> validate_length(:file_path, max: 500)
    |> validate_change(:file_path, fn :file_path, path ->
      case RepositoryPath.normalize(path) do
        {:ok, normalized} when normalized != "" -> []
        _invalid -> [file_path: "must be a safe repository-relative path"]
      end
    end)
    |> validate_length(:title, max: 200)
    |> validate_length(:description, max: 10_000)
    |> validate_inclusion(:disposition, ~w(new matches_existing regression not_reproduced))
    |> validate_number(:line_start, greater_than_or_equal_to: 1)
    |> validate_number(:line_end, greater_than_or_equal_to: 1)
    |> validate_number(:line_start, less_than_or_equal_to: 1_000_000)
    |> validate_number(:line_end, less_than_or_equal_to: 1_000_000)
    |> validate_line_order()
    |> check_constraint(:severity, name: :scan_findings_severity_must_be_valid)
    |> check_constraint(:line_start, name: :scan_findings_lines_must_be_ordered)
    |> check_constraint(:disposition, name: :scan_findings_disposition_must_be_valid)
  end

  defp validate_line_order(changeset) do
    line_start = get_field(changeset, :line_start)
    line_end = get_field(changeset, :line_end)

    cond do
      is_nil(line_start) and is_integer(line_end) ->
        add_error(changeset, :line_start, "is required when line_end is set")

      is_integer(line_start) and is_nil(line_end) ->
        add_error(changeset, :line_end, "is required when line_start is set")

      is_integer(line_start) and is_integer(line_end) and line_end < line_start ->
        add_error(changeset, :line_end, "must not be before line_start")

      true ->
        changeset
    end
  end
end
