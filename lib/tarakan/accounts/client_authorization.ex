defmodule Tarakan.Accounts.ClientAuthorization do
  @moduledoc """
  A short-lived browser approval initiated by Tarakan Client.

  The high-entropy device code is never stored directly. Approval binds the
  request to a browser-authenticated account; the API credential is created
  only when the client exchanges the secret device code.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account

  @statuses ~w(pending approved denied consumed expired)

  schema "client_authorizations" do
    field :device_code_hash, :binary, redact: true
    field :user_code, :string
    field :client_name, :string
    field :scopes, {:array, :string}, default: []
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def creation_changeset(authorization, attrs) do
    authorization
    |> cast(attrs, [:client_name, :scopes, :expires_at])
    |> validate_required([:client_name, :scopes, :expires_at])
    |> validate_length(:client_name, min: 1, max: 80)
    |> validate_length(:scopes, min: 1)
    |> check_constraint(:status, name: :client_authorizations_status_must_be_valid)
    |> unique_constraint(:device_code_hash)
    |> unique_constraint(:user_code)
  end
end
