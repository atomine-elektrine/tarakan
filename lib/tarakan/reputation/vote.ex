defmodule Tarakan.Reputation.Vote do
  @moduledoc """
  A single account's standing vote on a votable subject (a canonical finding
  or a discussion comment). Recasting overwrites the previous value; a value of
  `-1` or `+1` only — a neutral position is the absence of a row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account

  @subject_types ~w(canonical_finding comment)

  schema "votes" do
    field :subject_type, :string
    field :subject_id, :integer
    field :value, :integer

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  def subject_types, do: @subject_types

  @doc false
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:account_id, :subject_type, :subject_id, :value])
    |> validate_required([:account_id, :subject_type, :subject_id, :value])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:value, [-1, 1])
    |> unique_constraint([:account_id, :subject_type, :subject_id])
    |> check_constraint(:value, name: :votes_value_must_be_unit)
  end
end
