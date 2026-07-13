defmodule Tarakan.Moderation.Case do
  @moduledoc "A restricted report of potentially abusive or unsafe content."

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Repositories.Repository

  @subject_types ~w(repository account scan finding review_task contribution)
  @reasons ~w(spam unsafe_disclosure harassment plagiarism malicious_instructions fabricated_evidence secrets_or_pii other)
  @statuses ~w(open in_review resolved dismissed overturned)

  schema "moderation_cases" do
    field :subject_type, :string
    field :subject_id, :integer
    field :reason, :string
    field :description, :string
    field :status, :string, default: "open"
    field :resolution, :string
    field :resolved_at, :utc_datetime_usec

    belongs_to :reporter, Account
    belongs_to :subject_owner, Account
    belongs_to :repository, Repository
    belongs_to :assigned_to, Account
    belongs_to :resolved_by, Account
    has_many :actions, Tarakan.Moderation.Action, foreign_key: :moderation_case_id
    has_many :appeals, Tarakan.Moderation.Appeal, foreign_key: :moderation_case_id

    timestamps(type: :utc_datetime_usec)
  end

  def subject_types, do: @subject_types
  def reasons, do: @reasons
  def statuses, do: @statuses

  def report_changeset(case_record, attrs) do
    case_record
    |> cast(attrs, [:subject_type, :subject_id, :reason, :description])
    |> update_change(:description, &String.trim/1)
    |> validate_required([:subject_type, :subject_id, :reason, :description])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:reason, @reasons)
    |> validate_number(:subject_id, greater_than: 0)
    |> validate_length(:description, min: 10, max: 5_000)
    |> unique_constraint([:reporter_id, :subject_type, :subject_id],
      name: :moderation_cases_one_open_report_index,
      message: "you already have an open report for this content"
    )
    |> check_constraint(:subject_type, name: :moderation_cases_subject_type_must_be_valid)
    |> check_constraint(:reason, name: :moderation_cases_reason_must_be_valid)
  end
end
