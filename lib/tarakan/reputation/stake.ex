defmodule Tarakan.Reputation.Stake do
  @moduledoc """
  A reputation wager committed when a review is submitted.

  The row records only the amount put at risk; the *outcome* is derived from
  the parent scan's current state (verified → returned, contested → slashed,
  otherwise pending), so a review that is later re-verified automatically
  un-slashes without a separate write. See `Tarakan.Reputation`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Scans.Scan

  schema "review_stakes" do
    field :amount, :integer

    belongs_to :scan, Scan
    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(stake, attrs) do
    stake
    |> cast(attrs, [:scan_id, :account_id, :amount])
    |> validate_required([:scan_id, :account_id, :amount])
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> unique_constraint(:scan_id)
    |> check_constraint(:amount, name: :review_stakes_amount_positive)
  end
end
