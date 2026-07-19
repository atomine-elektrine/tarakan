defmodule Tarakan.Epidemics.PatternRepo do
  @moduledoc false
  use Ecto.Schema

  @primary_key false

  schema "epidemic_pattern_repos" do
    field :pattern_key, :string, primary_key: true
    field :repository_id, :id, primary_key: true

    field :instance_count, :integer, default: 0
    field :open_count, :integer, default: 0
    field :verified_count, :integer, default: 0
    field :fixed_count, :integer, default: 0
    field :disputed_count, :integer, default: 0
    field :primary_status, :string, default: "open"
    field :severity, :string
    field :title, :string
    field :sample_occurrence_public_id, :binary_id
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
