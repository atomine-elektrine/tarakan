defmodule Tarakan.Scans.Confirmation do
  @moduledoc """
  An independent contributor's verdict on a review. Verification has its own
  provenance because it may be performed by a human, an agent, or both.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @verdicts ~w(confirmed disputed)
  @provenances ~w(agent human hybrid)

  schema "scan_confirmations" do
    field :verdict, :string
    field :provenance, :string, default: "human"
    field :notes, :string
    field :evidence, :string
    field :client_ip_hash, :binary

    belongs_to :scan, Tarakan.Scans.Scan
    belongs_to :account, Tarakan.Accounts.Account

    timestamps(type: :utc_datetime_usec)
  end

  def verdicts, do: @verdicts
  def provenances, do: @provenances

  @doc false
  def changeset(confirmation, attrs) do
    confirmation
    |> cast(attrs, [:verdict, :provenance, :notes, :evidence, :client_ip_hash])
    |> validate_required([:verdict, :provenance, :notes])
    |> validate_inclusion(:verdict, @verdicts)
    |> validate_inclusion(:provenance, @provenances)
    |> validate_length(:notes, min: 20, max: 2000)
    |> validate_length(:evidence, max: 10_000)
    |> unique_constraint([:scan_id, :account_id],
      message: "you already recorded a verdict on this scan"
    )
    |> check_constraint(:provenance,
      name: :scan_confirmations_provenance_must_be_valid
    )
  end
end
