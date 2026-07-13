defmodule Tarakan.Accounts.ApiCredentials do
  @moduledoc """
  Lifecycle and authentication for scoped Tarakan Client credentials.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.{Account, ApiCredential, Scope}
  alias Tarakan.Audit
  alias Tarakan.Repo

  @default_validity_days 30
  @maximum_active_credentials 10
  @default_scopes ~w(tasks:read)

  def default_scopes, do: @default_scopes

  def create(%Account{} = account, attrs \\ %{}) do
    result =
      Repo.transaction(fn ->
        locked_account =
          Repo.one!(
            from candidate in Account,
              where: candidate.id == ^account.id,
              lock: "FOR UPDATE"
          )

        if active_count(locked_account) >= @maximum_active_credentials do
          Repo.rollback(:credential_limit)
        end

        token = "trkn_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
        expires_at = DateTime.add(DateTime.utc_now(), @default_validity_days, :day)

        attrs =
          attrs
          |> Map.new(fn {key, value} -> {to_string(key), value} end)
          |> Map.put_new("name", "Tarakan Client")
          |> Map.put_new("scopes", @default_scopes)
          |> Map.put("expires_at", expires_at)

        changeset =
          %ApiCredential{}
          |> ApiCredential.creation_changeset(attrs)
          |> Ecto.Changeset.put_change(:account_id, locked_account.id)
          |> Ecto.Changeset.put_change(:token_hash, token_hash(token))
          |> Ecto.Changeset.put_change(:token_prefix, String.slice(token, 0, 13))

        credential =
          case Repo.insert(changeset) do
            {:ok, credential} -> credential
            {:error, changeset} -> Repo.rollback(changeset)
          end

        audit_scope = Scope.for_account(locked_account, authentication_method: :session)

        audit_scope
        |> Audit.event_changeset(:api_credential_created, credential, %{
          to_state: "active",
          metadata: %{
            name: credential.name,
            scopes: credential.scopes,
            repository_id: credential.repository_id
          }
        })
        |> Repo.insert!()

        {token, credential}
      end)

    case result do
      {:ok, {token, credential}} -> {:ok, token, credential}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_active(id, account_id) when is_integer(id) and is_integer(account_id) do
    now = DateTime.utc_now()

    case Repo.one(
           from credential in ApiCredential,
             where:
               credential.id == ^id and credential.account_id == ^account_id and
                 is_nil(credential.revoked_at) and credential.expires_at > ^now
         ) do
      %ApiCredential{} = credential -> {:ok, credential}
      nil -> :error
    end
  end

  def fetch_active(_id, _account_id), do: :error

  def authenticate(<<"trkn_", encoded::binary-size(43)>> = token) do
    if encoded =~ ~r/^[A-Za-z0-9_-]+$/ do
      authenticate_well_formed(token)
    else
      :error
    end
  end

  def authenticate(_token), do: :error

  defp authenticate_well_formed(token) do
    now = DateTime.utc_now()

    credential =
      Repo.one(
        from credential in ApiCredential,
          where:
            credential.token_hash == ^token_hash(token) and
              is_nil(credential.revoked_at) and credential.expires_at > ^now,
          preload: :account
      )

    case credential do
      %ApiCredential{account: %Account{} = account} = credential ->
        if Account.access_allowed?(account) do
          timestamp = DateTime.utc_now()
          maybe_touch_last_used(credential, timestamp)
          {:ok, account, %{credential | last_used_at: timestamp}}
        else
          :error
        end

      nil ->
        :error
    end
  end

  # Avoid a write on every authenticated API call; once a minute is enough.
  defp maybe_touch_last_used(%ApiCredential{id: id, last_used_at: last_used_at}, timestamp) do
    stale? =
      is_nil(last_used_at) or
        DateTime.diff(timestamp, last_used_at, :second) >= 60

    if stale? do
      from(stored in ApiCredential, where: stored.id == ^id)
      |> Repo.update_all(set: [last_used_at: timestamp])
    end

    :ok
  end

  def list(%Account{id: account_id}) do
    ApiCredential
    |> where([credential], credential.account_id == ^account_id)
    |> order_by([credential], desc: credential.inserted_at)
    |> preload(:repository)
    |> Repo.all()
  end

  def revoke(%Account{id: account_id}, credential_id) do
    result =
      Repo.transaction(fn ->
        account =
          Repo.one!(
            from candidate in Account,
              where: candidate.id == ^account_id,
              lock: "FOR UPDATE"
          )

        credential =
          Repo.one(
            from candidate in ApiCredential,
              where: candidate.id == ^credential_id and candidate.account_id == ^account_id,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:not_found)

        if credential.revoked_at do
          credential
        else
          revoked =
            credential
            |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
            |> Repo.update!()

          Scope.for_account(account, authentication_method: :session)
          |> Audit.event_changeset(:api_credential_revoked, revoked, %{
            from_state: "active",
            to_state: "revoked"
          })
          |> Repo.insert!()

          revoked
        end
      end)

    case result do
      {:ok, credential} -> {:ok, credential}
      {:error, reason} -> {:error, reason}
    end
  end

  def scope_granted?(%ApiCredential{scopes: scopes}, scope), do: scope in scopes
  def scope_granted?(_credential, _scope), do: false

  defp active_count(%Account{id: account_id}) do
    now = DateTime.utc_now()

    Repo.aggregate(
      from(credential in ApiCredential,
        where:
          credential.account_id == ^account_id and is_nil(credential.revoked_at) and
            credential.expires_at > ^now
      ),
      :count
    )
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)
end
