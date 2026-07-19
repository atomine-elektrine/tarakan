defmodule Tarakan.Epidemics.Pattern do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:pattern_key, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "epidemic_patterns" do
    field :title, :string
    field :severity, :string
    field :sample_file_path, :string
    field :sample_occurrence_public_id, :binary_id

    field :repo_count, :integer, default: 0
    field :instance_count, :integer, default: 0
    field :open_count, :integer, default: 0
    field :verified_count, :integer, default: 0
    field :fixed_count, :integer, default: 0
    field :disputed_count, :integer, default: 0

    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    field :repo_count_7d, :integer, default: 0
    field :instance_count_7d, :integer, default: 0
    field :open_count_7d, :integer, default: 0
    field :verified_count_7d, :integer, default: 0
    field :fixed_count_7d, :integer, default: 0
    field :disputed_count_7d, :integer, default: 0
    field :last_seen_at_7d, :utc_datetime_usec

    field :repo_count_30d, :integer, default: 0
    field :instance_count_30d, :integer, default: 0
    field :open_count_30d, :integer, default: 0
    field :verified_count_30d, :integer, default: 0
    field :fixed_count_30d, :integer, default: 0
    field :disputed_count_30d, :integer, default: 0
    field :last_seen_at_30d, :utc_datetime_usec

    field :repo_count_90d, :integer, default: 0
    field :instance_count_90d, :integer, default: 0
    field :open_count_90d, :integer, default: 0
    field :verified_count_90d, :integer, default: 0
    field :fixed_count_90d, :integer, default: 0
    field :disputed_count_90d, :integer, default: 0
    field :last_seen_at_90d, :utc_datetime_usec

    field :repo_count_365d, :integer, default: 0
    field :instance_count_365d, :integer, default: 0
    field :open_count_365d, :integer, default: 0
    field :verified_count_365d, :integer, default: 0
    field :fixed_count_365d, :integer, default: 0
    field :disputed_count_365d, :integer, default: 0
    field :last_seen_at_365d, :utc_datetime_usec

    field :refreshed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
