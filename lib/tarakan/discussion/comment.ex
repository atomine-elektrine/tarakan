defmodule Tarakan.Discussion.Comment do
  @moduledoc """
  A threaded discussion comment on a finding.

  Comments are public the moment they are posted and can only be taken down
  by moderation (`removed_at`), which keeps the comment's place in the thread
  and hides its body behind a placeholder. Threads nest through `parent_id`;
  `@max_depth` caps how deep a reply chain can grow so the tree stays
  renderable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.Finding

  @max_depth 8

  schema "finding_comments" do
    field :body, :string
    field :removed_at, :utc_datetime_usec
    field :removed_reason, :string

    # Rendering helpers, populated by Tarakan.Discussion - not persisted.
    field :depth, :integer, virtual: true, default: 0
    field :replies, {:array, :any}, virtual: true, default: []

    belongs_to :finding, Finding
    belongs_to :repository, Repository
    belongs_to :account, Account
    belongs_to :parent, __MODULE__
    belongs_to :removed_by, Account

    timestamps(type: :utc_datetime_usec)
  end

  def max_depth, do: @max_depth

  @doc false
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: 10_000)
  end

  @doc false
  def removal_changeset(comment, attrs, remover_id) do
    comment
    |> cast(attrs, [:removed_reason])
    |> put_change(:removed_at, DateTime.utc_now())
    |> put_change(:removed_by_id, remover_id)
    |> validate_required([:removed_reason])
    |> validate_length(:removed_reason, min: 3, max: 100)
  end
end
