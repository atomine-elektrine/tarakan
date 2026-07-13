defmodule Tarakan.Repositories.RepositoryMembership do
  @moduledoc """
  A verified or proposed relationship between an account and a repository.

  Registration alone never creates this relationship. A membership is useful
  for authorization only while its status is `verified`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account
  alias Tarakan.Repositories.Repository

  @roles ~w(steward reviewer)
  @statuses ~w(verified pending revoked)

  schema "repository_memberships" do
    field :role, :string
    field :status, :string, default: "pending"
    field :verified_at, :utc_datetime_usec

    belongs_to :repository, Repository
    belongs_to :account, Account
    belongs_to :verified_by_account, Account

    timestamps(type: :utc_datetime_usec)
  end

  def roles, do: @roles
  def statuses, do: @statuses

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
    |> check_constraint(:role, name: :repository_memberships_role_must_be_valid)
    |> unique_constraint([:repository_id, :account_id])
  end

  @doc false
  def status_changeset(membership, status, verifier) do
    membership
    |> change()
    |> put_change(:status, status)
    |> put_verification(status, verifier)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :repository_memberships_status_must_be_valid)
    |> check_constraint(:status,
      name: :repository_memberships_verified_state_must_be_consistent
    )
  end

  defp put_verification(changeset, "verified", %Account{id: verifier_id}) do
    changeset
    |> put_change(:verified_at, DateTime.utc_now(:microsecond))
    |> put_change(:verified_by_account_id, verifier_id)
  end

  defp put_verification(changeset, "verified", nil) do
    changeset
    |> put_change(:verified_at, DateTime.utc_now(:microsecond))
    |> put_change(:verified_by_account_id, nil)
  end

  defp put_verification(changeset, _status, _verifier) do
    changeset
    |> put_change(:verified_at, nil)
    |> put_change(:verified_by_account_id, nil)
  end
end
