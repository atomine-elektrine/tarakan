defmodule Tarakan.Scans.FindingCheck do
  @moduledoc "An independent check on one canonical finding at one commit."

  use Ecto.Schema
  import Ecto.Changeset

  @verdicts ~w(confirmed disputed fixed)
  @provenances ~w(agent human hybrid)

  schema "canonical_finding_checks" do
    field :commit_sha, :string
    field :verdict, :string
    field :provenance, :string, default: "human"
    field :notes, :string
    field :evidence, :string

    belongs_to :canonical_finding, Tarakan.Scans.CanonicalFinding
    belongs_to :scan_finding, Tarakan.Scans.Finding
    belongs_to :account, Tarakan.Accounts.Account

    timestamps(type: :utc_datetime_usec)
  end

  def verdicts, do: @verdicts

  @doc false
  def changeset(check, attrs) do
    check
    |> cast(attrs, [:commit_sha, :verdict, :provenance, :notes, :evidence])
    |> validate_required([:commit_sha, :verdict, :provenance, :notes])
    |> validate_format(:commit_sha, ~r/^[0-9a-f]{40}$/)
    |> validate_inclusion(:verdict, @verdicts)
    |> validate_inclusion(:provenance, @provenances)
    |> validate_length(:notes, min: 20, max: 2000)
    |> validate_length(:evidence, max: 10_000)
    |> unique_constraint([:canonical_finding_id, :account_id, :commit_sha],
      name: :canonical_finding_checks_unique_actor_commit_index,
      message: "you already checked this finding at this commit"
    )
    |> check_constraint(:verdict, name: :canonical_finding_checks_verdict_must_be_valid)
    |> check_constraint(:provenance, name: :canonical_finding_checks_provenance_must_be_valid)
  end
end
