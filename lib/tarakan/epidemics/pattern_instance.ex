defmodule Tarakan.Epidemics.PatternInstance do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:canonical_finding_id, :id, autogenerate: false}

  schema "epidemic_pattern_instances" do
    field :pattern_key, :string
    field :repository_id, :id
    field :status, :string
    field :severity, :string
    field :title, :string
    field :file_path, :string
    field :sample_occurrence_public_id, :binary_id
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
