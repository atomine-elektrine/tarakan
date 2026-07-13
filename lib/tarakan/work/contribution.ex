defmodule Tarakan.Work.Contribution do
  @moduledoc """
  The evidence submitted to complete a review task.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Work.ReviewTask

  @provenances ~w(human agent hybrid)

  schema "review_task_contributions" do
    field :version, :integer
    field :provenance, :string, default: "human"
    field :summary, :string
    field :evidence, :string

    belongs_to :review_task, ReviewTask
    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  def provenances, do: @provenances

  def changeset(contribution, attrs) do
    contribution
    |> cast(attrs, [:provenance, :summary, :evidence])
    |> update_change(:summary, &String.trim/1)
    |> update_change(:evidence, &String.trim/1)
    |> validate_required([:provenance, :summary, :evidence])
    |> validate_inclusion(:provenance, @provenances)
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:summary, max: 2_000)
    |> validate_length(:evidence, min: 20, max: 10_000)
    |> unique_constraint([:review_task_id, :version])
    |> check_constraint(:provenance,
      name: :review_task_contributions_provenance_must_be_valid
    )
  end
end
