defmodule Tarakan.Moderation.Appeal do
  @moduledoc "An appeal decided by a moderator other than the original resolver."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(open upheld denied)

  def statuses, do: @statuses

  schema "moderation_appeals" do
    field :reason, :string
    field :status, :string, default: "open"
    field :decision_reason, :string
    field :decided_at, :utc_datetime_usec

    belongs_to :moderation_case, Tarakan.Moderation.Case
    belongs_to :appellant, Tarakan.Accounts.Account
    belongs_to :decided_by, Tarakan.Accounts.Account

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(appeal, attrs) do
    appeal
    |> cast(attrs, [:reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:reason])
    |> validate_length(:reason, min: 20, max: 5_000)
    |> unique_constraint([:moderation_case_id, :appellant_id])
  end

  def decision_changeset(appeal, status, reason, moderator) do
    appeal
    |> cast(%{status: status, decision_reason: reason}, [:status, :decision_reason])
    |> update_change(:decision_reason, &String.trim/1)
    |> put_change(:decided_by_id, moderator.id)
    |> put_change(:decided_at, DateTime.utc_now())
    |> validate_required([:status, :decision_reason])
    |> validate_inclusion(:status, ~w(upheld denied))
    |> validate_length(:decision_reason, min: 10, max: 2_000)
    |> check_constraint(:status, name: :moderation_appeals_status_must_be_valid)
  end
end
