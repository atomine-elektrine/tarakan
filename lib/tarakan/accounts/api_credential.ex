defmodule Tarakan.Accounts.ApiCredential do
  @moduledoc """
  A named, scoped, individually revocable credential for Tarakan Client.

  Only the SHA-256 hash is stored. The plaintext token is returned once when
  the credential is created.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Repositories.Repository

  # Request-complete Review path needs findings:submit (or reviews:submit) in
  # addition to contributions:write. Prefer reviews:* names going forward.
  @scopes ~w(
    tasks:read tasks:claim contributions:write
    findings:submit findings:verify findings:read
    reviews:submit reviews:read reviews:verify
    reports:write repo:read repo:write discussion:write
    requests:read requests:claim
  )

  schema "api_credentials" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :token_prefix, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :account, Account
    belongs_to :repository, Repository

    timestamps(type: :utc_datetime_usec)
  end

  def scopes, do: @scopes

  def creation_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:name, :scopes, :repository_id, :expires_at])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :scopes, :expires_at])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_subset(:scopes, @scopes)
    |> validate_length(:scopes, min: 1)
    |> check_constraint(:scopes, name: :api_credentials_scopes_must_be_valid)
    |> foreign_key_constraint(:repository_id)
  end

  def active?(%__MODULE__{revoked_at: nil, expires_at: expires_at}) do
    DateTime.after?(expires_at, DateTime.utc_now())
  end

  def active?(_credential), do: false
end
