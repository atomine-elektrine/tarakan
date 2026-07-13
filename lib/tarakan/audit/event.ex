defmodule Tarakan.Audit.Event do
  @moduledoc """
  An immutable record of a security-relevant state transition.

  The database rejects updates and deletes from this table. Corrections are
  represented by later events rather than rewriting history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Repositories.Repository

  schema "audit_events" do
    field :token_id, :integer
    field :action, :string
    field :subject_type, :string
    field :subject_id, :integer
    field :from_state, :string
    field :to_state, :string
    field :reason_code, :string
    field :request_id, :string
    field :client_version, :string
    field :metadata, :map, default: %{}

    belongs_to :actor, Account
    belongs_to :repository, Repository

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def append_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :action,
      :subject_type,
      :subject_id,
      :repository_id,
      :from_state,
      :to_state,
      :reason_code,
      :request_id,
      :client_version,
      :metadata
    ])
    |> validate_required([:action])
    |> validate_length(:action, max: 120)
    |> validate_length(:subject_type, max: 160)
    |> validate_length(:from_state, max: 120)
    |> validate_length(:to_state, max: 120)
    |> validate_length(:reason_code, max: 120)
    |> validate_length(:request_id, max: 255)
    |> validate_length(:client_version, max: 120)
  end
end
