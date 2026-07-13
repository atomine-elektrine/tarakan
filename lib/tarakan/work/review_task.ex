defmodule Tarakan.Work.ReviewTask do
  @moduledoc """
  A commit-pinned unit of security work that a contributor can claim.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.Scan
  alias Tarakan.Work.Contribution

  @kinds ~w(code_review threat_model privacy_review business_logic verify_findings write_fix)
  @capabilities ~w(human agent hybrid)
  @statuses ~w(proposed open claimed submitted accepted changes_requested rejected cancelled)
  @visibilities ~w(restricted public_summary public)
  @public_statuses ~w(open claimed accepted)
  @claimable_statuses ~w(open changes_requested)
  @terminal_statuses ~w(accepted rejected cancelled)

  schema "review_tasks" do
    field :commit_sha, :string
    field :commit_committed_at, :utc_datetime_usec
    field :kind, :string
    field :capability, :string, default: "human"
    field :title, :string
    field :description, :string
    field :status, :string, default: "proposed"
    field :visibility, :string, default: "public"
    field :claimed_at, :utc_datetime_usec
    field :claim_expires_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec
    field :submitted_at, :utc_datetime_usec
    field :reviewed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :disclosed_at, :utc_datetime_usec
    field :sensitive_data_reviewed_at, :utc_datetime_usec

    belongs_to :repository, Repository
    belongs_to :created_by, Account
    belongs_to :claimed_by, Account
    belongs_to :reviewed_by, Account
    belongs_to :disclosed_by, Account
    belongs_to :sensitive_data_reviewed_by, Account
    belongs_to :contribution, Contribution, foreign_key: :latest_contribution_id
    # Latest Review produced when this Request was completed (domain collapse PR 1a).
    belongs_to :linked_review, Scan, foreign_key: :linked_review_id
    # For verify_findings: the Review being independently verified (PR5.1).
    belongs_to :target_review, Scan, foreign_key: :target_review_id
    has_many :contributions, Contribution
    has_many :decisions, Tarakan.Work.ReviewDecision
    # All Reviews whose source_request_id points here (resubmit history).
    has_many :produced_reviews, Scan, foreign_key: :source_request_id

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def capabilities, do: @capabilities
  def statuses, do: @statuses
  def visibilities, do: @visibilities
  def public_statuses, do: @public_statuses
  def claimable_statuses, do: @claimable_statuses
  def terminal_statuses, do: @terminal_statuses

  def creation_changeset(task, attrs) do
    task
    |> cast(attrs, [:commit_sha, :kind, :capability, :title, :description, :target_review_id])
    |> update_change(:commit_sha, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:title, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> validate_required([:commit_sha, :kind, :capability, :title, :description])
    |> validate_format(:commit_sha, ~r/^[0-9a-f]{40}$/,
      message: "must be a full 40-character commit SHA"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:capability, @capabilities)
    |> validate_length(:title, max: 160)
    |> validate_length(:description, max: 5_000)
    |> validate_target_review_kind()
    |> foreign_key_constraint(:target_review_id)
    |> check_constraint(:commit_sha, name: :review_tasks_commit_sha_must_be_full_sha)
    |> check_constraint(:kind, name: :review_tasks_kind_must_be_valid)
    |> check_constraint(:capability, name: :review_tasks_capability_must_be_valid)
  end

  defp validate_target_review_kind(changeset) do
    kind = get_field(changeset, :kind)
    target = get_field(changeset, :target_review_id)

    cond do
      kind == "verify_findings" and is_nil(target) ->
        add_error(changeset, :target_review_id, "is required for verify_findings requests")

      kind != "verify_findings" and not is_nil(target) ->
        add_error(changeset, :target_review_id, "is only valid for verify_findings requests")

      true ->
        changeset
    end
  end

  def claim_active?(%__MODULE__{status: "claimed", claim_expires_at: expires_at})
      when not is_nil(expires_at) do
    DateTime.after?(expires_at, DateTime.utc_now())
  end

  def claim_active?(_task), do: false

  # Visibility is the only content gate; status is a workflow label.
  def public?(%__MODULE__{visibility: visibility}) do
    visibility in ["public_summary", "public"]
  end

  def claimable?(%__MODULE__{status: status}), do: status in @claimable_statuses
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses
end
