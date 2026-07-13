defmodule Tarakan.Scans.CanonicalFinding do
  @moduledoc """
  A repository-level security issue assembled from immutable finding occurrences.

  Exact deterministic matches are linked automatically. Raw report findings remain
  unchanged so provenance is never rewritten during assimilation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.{Finding, FindingCheck}

  @statuses ~w(open verified disputed fixed)

  schema "canonical_findings" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :fingerprint, :string
    field :file_path, :string
    field :line_start, :integer
    field :line_end, :integer
    field :severity, :string
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"
    field :first_seen_commit_sha, :string
    field :last_seen_commit_sha, :string
    field :detections_count, :integer, default: 0
    field :distinct_submitters_count, :integer, default: 0
    field :distinct_models_count, :integer, default: 0
    field :confirmations_count, :integer, default: 0
    field :disputes_count, :integer, default: 0
    field :verified_at, :utc_datetime_usec

    belongs_to :repository, Repository
    has_many :occurrences, Finding
    has_many :checks, FindingCheck

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [
      :repository_id,
      :fingerprint,
      :file_path,
      :line_start,
      :line_end,
      :severity,
      :title,
      :description,
      :status,
      :first_seen_commit_sha,
      :last_seen_commit_sha,
      :detections_count,
      :distinct_submitters_count,
      :distinct_models_count,
      :confirmations_count,
      :disputes_count,
      :verified_at
    ])
    |> validate_required([
      :repository_id,
      :fingerprint,
      :file_path,
      :severity,
      :title,
      :description,
      :status,
      :first_seen_commit_sha,
      :last_seen_commit_sha
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:repository_id, :fingerprint])
    |> check_constraint(:status, name: :canonical_findings_status_must_be_valid)
  end
end
