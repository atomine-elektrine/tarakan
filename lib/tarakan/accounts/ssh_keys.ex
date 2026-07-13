defmodule Tarakan.Accounts.SshKeys do
  @moduledoc """
  Managing and resolving registered SSH public keys.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.{Account, SshKey}
  alias Tarakan.Repo

  @maximum_keys_per_account 10

  def list_for_account(%Account{id: account_id}) do
    SshKey
    |> where([key], key.account_id == ^account_id)
    |> order_by([key], asc: key.inserted_at)
    |> Repo.all()
  end

  @doc "Registers a pasted OpenSSH public key for an account."
  def add_key(%Account{} = account, attrs) do
    Repo.transaction(fn ->
      # Serialize on the account row so concurrent adds cannot blow the cap.
      _locked =
        Repo.one!(
          from candidate in Account, where: candidate.id == ^account.id, lock: "FOR UPDATE"
        )

      count =
        SshKey
        |> where([key], key.account_id == ^account.id)
        |> Repo.aggregate(:count)

      if count >= @maximum_keys_per_account do
        Repo.rollback(:key_limit)
      end

      %SshKey{account_id: account.id}
      |> SshKey.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, key} -> key
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Removes one of the account's own keys."
  def delete_key(%Account{id: account_id}, key_id) do
    case Repo.get_by(SshKey, id: key_id, account_id: account_id) do
      %SshKey{} = key ->
        Repo.delete(key)

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Resolves a decoded public key (as presented during SSH auth) to its account.

  The global fingerprint uniqueness makes this a pure lookup.
  """
  def find_account_by_key(public_key) do
    fingerprint = SshKey.fingerprint(public_key)

    query =
      from key in SshKey,
        where: key.fingerprint_sha256 == ^fingerprint,
        join: account in assoc(key, :account),
        preload: [account: account]

    case Repo.one(query) do
      %SshKey{} = key -> {:ok, key.account, key}
      nil -> :error
    end
  rescue
    _error -> :error
  end

  def touch_last_used(%SshKey{id: id}) do
    from(key in SshKey, where: key.id == ^id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:microsecond)])

    :ok
  end
end
