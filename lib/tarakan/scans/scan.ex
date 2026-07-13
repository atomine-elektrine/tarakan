defmodule Tarakan.Scans.Scan do
  @moduledoc """
  A contributed security review pinned to an exact commit SHA. Provenance
  records whether the work was human-authored, agent-generated, or hybrid.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.{Confirmation, Finding, ScanFormat}
  alias Tarakan.Work.ReviewTask

  @provenances ~w(agent human hybrid)
  @review_kinds ~w(code_review threat_model privacy_review business_logic)
  @review_statuses ~w(quarantined accepted rejected contested)
  @visibilities ~w(restricted public_summary public)

  schema "scans" do
    field :commit_sha, :string
    field :commit_committed_at, :utc_datetime_usec
    field :model, :string
    field :prompt_version, :string
    field :run_id, :string
    field :provenance, :string, default: "agent"
    field :review_kind, :string, default: "code_review"
    field :notes, :string
    field :findings_count, :integer, default: 0
    field :confirmations_count, :integer, default: 0
    field :disputes_count, :integer, default: 0
    field :verified_at, :utc_datetime_usec
    field :review_status, :string, default: "quarantined"
    field :visibility, :string, default: "public"
    field :moderation_reason, :string
    field :moderation_notes, :string
    field :reviewed_at, :utc_datetime_usec
    field :raw_document, :string
    field :findings_json, :string, virtual: true
    field :details_visible, :boolean, virtual: true, default: false

    belongs_to :repository, Repository
    belongs_to :submitted_by, Account
    belongs_to :reviewed_by, Account
    # Optional Request that produced this Review (nil for ad-hoc submissions).
    belongs_to :source_request, ReviewTask, foreign_key: :source_request_id
    has_many :findings, Finding, preload_order: [asc: :position]
    has_many :confirmations, Confirmation

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def submission_changeset(scan, attrs) do
    scan
    |> cast(attrs, [
      :commit_sha,
      :model,
      :prompt_version,
      :run_id,
      :provenance,
      :review_kind,
      :notes,
      :findings_json
    ])
    |> update_change(:commit_sha, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:model, &String.trim/1)
    |> update_change(:prompt_version, &String.trim/1)
    |> validate_required([:commit_sha, :provenance, :review_kind])
    |> validate_inclusion(:provenance, @provenances)
    |> validate_inclusion(:review_kind, @review_kinds)
    |> validate_agent_metadata()
    |> validate_format(:commit_sha, ~r/^[0-9a-f]{40}$/,
      message: "must be a full 40-character commit SHA"
    )
    |> validate_length(:model, max: 100)
    |> validate_length(:prompt_version, max: 100)
    |> validate_length(:run_id, max: 200)
    |> validate_length(:notes, max: 2000)
    |> check_constraint(:provenance, name: :scans_provenance_must_be_valid)
    |> check_constraint(:review_kind, name: :scans_review_kind_must_be_valid)
    |> put_raw_document()
    |> put_findings()
    |> unique_constraint(:run_id,
      name: :scans_unique_run_index,
      message: "this agent run was already submitted"
    )
  end

  def provenances, do: @provenances
  def review_kinds, do: @review_kinds
  def review_statuses, do: @review_statuses
  def visibilities, do: @visibilities

  def verified?(%__MODULE__{verified_at: verified_at}), do: not is_nil(verified_at)

  def publicly_listed?(%__MODULE__{visibility: visibility})
      when visibility in ["public_summary", "public"],
      do: true

  def publicly_listed?(%__MODULE__{}), do: false

  @doc false
  def moderation_changeset(scan, status, attrs, reviewer_id) do
    scan
    |> cast(attrs, [:visibility, :moderation_reason, :moderation_notes])
    |> put_change(:review_status, status)
    |> put_change(:reviewed_by_id, reviewer_id)
    |> put_change(:reviewed_at, DateTime.utc_now())
    |> validate_required([:review_status, :visibility, :moderation_reason, :moderation_notes])
    |> validate_inclusion(:review_status, @review_statuses)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_length(:moderation_reason, min: 3, max: 100)
    |> validate_length(:moderation_notes, min: 20, max: 4000)
    |> validate_transition_rules()
    |> check_constraint(:review_status, name: :scans_review_status_must_be_valid)
    |> check_constraint(:visibility, name: :scans_visibility_must_be_valid)
    |> check_constraint(:review_status, name: :scans_acceptance_requires_verification)
    |> check_constraint(:review_status, name: :scans_acceptance_requires_quorum)
    |> check_constraint(:review_status, name: :scans_moderation_requires_attribution)
  end

  @doc false
  def quorum_lost_changeset(scan) do
    scan
    |> change(
      verified_at: nil,
      review_status: "contested",
      moderation_reason: "verification_quorum_lost",
      moderation_notes:
        "A later independent verdict removed the verification quorum; the review was marked contested automatically."
    )
    |> check_constraint(:review_status, name: :scans_review_status_must_be_valid)
    |> check_constraint(:visibility, name: :scans_visibility_must_be_valid)
    |> check_constraint(:review_status, name: :scans_moderation_requires_attribution)
  end

  defp validate_agent_metadata(changeset) do
    case get_field(changeset, :provenance) do
      "human" -> changeset
      _provenance -> validate_required(changeset, [:model, :prompt_version])
    end
  end

  defp validate_transition_rules(changeset) do
    status = get_field(changeset, :review_status)
    verified_at = get_field(changeset, :verified_at)

    if status == "accepted" and is_nil(verified_at) do
      add_error(changeset, :review_status, "cannot be accepted before verification quorum")
    else
      changeset
    end
  end

  # Keeps the submitted Tarakan Scan Format document verbatim - the model's
  # raw report - alongside the parsed findings rows.
  defp put_raw_document(changeset) do
    case get_field(changeset, :findings_json) do
      nil ->
        changeset

      json ->
        changeset
        |> put_change(:raw_document, json)
        |> validate_length(:raw_document, max: 2_000_000)
    end
  end

  defp put_findings(changeset) do
    case ScanFormat.parse(get_field(changeset, :findings_json)) do
      {:ok, findings} ->
        finding_changesets = Enum.map(findings, &Finding.changeset(%Finding{}, &1))

        changeset
        |> put_assoc(:findings, finding_changesets)
        |> put_change(:findings_count, length(finding_changesets))
        |> surface_finding_errors(finding_changesets)

      {:error, message} ->
        add_error(changeset, :findings_json, message)
    end
  end

  # put_assoc records child errors on the association, which the submission
  # form cannot display; repeat the first one on the findings_json field.
  defp surface_finding_errors(changeset, finding_changesets) do
    case Enum.find_index(finding_changesets, &(not &1.valid?)) do
      nil ->
        changeset

      index ->
        {field, {message, _meta}} =
          finding_changesets |> Enum.at(index) |> Map.fetch!(:errors) |> List.first()

        add_error(changeset, :findings_json, "findings[#{index}]: #{field} #{message}")
    end
  end
end
