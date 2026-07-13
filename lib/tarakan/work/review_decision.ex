defmodule Tarakan.Work.ReviewDecision do
  @moduledoc """
  An immutable, attributable decision in a review task's lifecycle.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Work.ReviewTask

  @actions ~w(publish accept request_changes reject cancel disclose)
  @evidence_actions ~w(accept request_changes reject)

  schema "review_task_decisions" do
    field :action, :string
    field :reason, :string
    field :evidence, :string

    belongs_to :review_task, ReviewTask
    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def actions, do: @actions

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:action, :reason, :evidence])
    |> update_change(:reason, &String.trim/1)
    |> update_change(:evidence, &String.trim/1)
    |> validate_required([:action, :reason])
    |> validate_inclusion(:action, @actions)
    |> validate_length(:reason, min: 10, max: 2_000)
    |> validate_length(:evidence, min: 20, max: 10_000)
    |> require_review_evidence()
    |> check_constraint(:action, name: :review_task_decisions_action_must_be_valid)
  end

  defp require_review_evidence(changeset) do
    if get_field(changeset, :action) in @evidence_actions do
      validate_required(changeset, [:evidence])
    else
      changeset
    end
  end
end
