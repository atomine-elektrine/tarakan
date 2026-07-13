defmodule Tarakan.Accounts.ClientAuthorizations do
  @moduledoc """
  Short-lived device authorization for browser-based Tarakan Client login.

  A client holds a high-entropy device code while a signed-in browser approves
  the displayed user code. Approval never places an API credential in a URL;
  the credential is minted once, during the device-code exchange.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tarakan.Accounts.{Account, AccountToken, ApiCredentials, ClientAuthorization}
  alias Tarakan.Repo

  @validity_minutes 10
  @poll_interval_seconds 2
  @client_scopes ~w(
    tasks:read tasks:claim contributions:write
    reviews:submit reviews:read reviews:verify
  )

  def validity_seconds, do: @validity_minutes * 60
  def poll_interval_seconds, do: @poll_interval_seconds
  def client_scopes, do: @client_scopes

  def start(attrs \\ %{}) do
    _ = prune_expired()

    client_name =
      attrs |> Map.get("client_name", "Tarakan Client") |> to_string() |> String.trim()

    device_code = "trkd_" <> random_url_token(32)
    user_code = random_user_code()
    expires_at = DateTime.add(DateTime.utc_now(), @validity_minutes, :minute)

    changeset =
      %ClientAuthorization{}
      |> ClientAuthorization.creation_changeset(%{
        "client_name" => client_name,
        "scopes" => @client_scopes,
        "expires_at" => expires_at
      })
      |> Changeset.put_change(:device_code_hash, token_hash(device_code))
      |> Changeset.put_change(:user_code, normalize_user_code(user_code))

    case Repo.insert(changeset) do
      {:ok, authorization} ->
        {:ok, device_code, display_user_code(user_code), authorization}

      {:error, %Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :user_code), do: start(attrs), else: error
    end
  end

  def get_for_browser(user_code) when is_binary(user_code) do
    now = DateTime.utc_now()

    case Repo.one(
           from authorization in ClientAuthorization,
             where:
               authorization.user_code == ^normalize_user_code(user_code) and
                 authorization.status in ["pending", "approved", "denied"] and
                 authorization.expires_at > ^now
         ) do
      %ClientAuthorization{} = authorization -> {:ok, authorization}
      nil -> {:error, :not_found}
    end
  end

  def get_for_browser(_user_code), do: {:error, :not_found}

  def approve(%ClientAuthorization{id: id}, %Account{} = account) do
    transition(id, fn authorization ->
      now = DateTime.utc_now()

      cond do
        DateTime.compare(authorization.expires_at, now) != :gt ->
          {:error, :expired}

        authorization.status == "pending" ->
          authorization
          |> Changeset.change(status: "approved", account_id: account.id, approved_at: now)
          |> Repo.update()

        authorization.status == "approved" and authorization.account_id == account.id ->
          {:ok, authorization}

        true ->
          {:error, :not_found}
      end
    end)
  end

  def deny(%ClientAuthorization{id: id}, %Account{} = account) do
    transition(id, fn authorization ->
      cond do
        authorization.status == "pending" ->
          authorization
          |> Changeset.change(status: "denied", account_id: account.id)
          |> Repo.update()

        authorization.status == "denied" and authorization.account_id == account.id ->
          {:ok, authorization}

        true ->
          {:error, :not_found}
      end
    end)
  end

  def exchange(device_code) when is_binary(device_code) do
    if valid_device_code?(device_code) do
      Repo.transaction(fn ->
        authorization =
          Repo.one(
            from candidate in ClientAuthorization,
              where: candidate.device_code_hash == ^token_hash(device_code),
              lock: "FOR UPDATE"
          ) || Repo.rollback(:invalid_device_code)

        exchange_locked(authorization)
      end)
    else
      {:error, :invalid_device_code}
    end
  end

  def exchange(_device_code), do: {:error, :invalid_device_code}

  defp exchange_locked(authorization) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(authorization.expires_at, now) != :gt ->
        Repo.rollback(:expired)

      authorization.status == "pending" ->
        Repo.rollback(:authorization_pending)

      authorization.status == "denied" ->
        Repo.rollback(:access_denied)

      authorization.status != "approved" or is_nil(authorization.account_id) ->
        Repo.rollback(:invalid_device_code)

      true ->
        account = Repo.get!(Account, authorization.account_id)

        if not Account.access_allowed?(account) do
          Repo.rollback(:account_locked)
        end

        case ApiCredentials.create(account, %{
               "name" => authorization.client_name,
               "scopes" => authorization.scopes
             }) do
          {:ok, token, credential} ->
            authorization
            |> Changeset.change(status: "consumed", consumed_at: now)
            |> Repo.update!()

            {token, credential}

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  defp prune_expired do
    now = DateTime.utc_now()

    # Delete by the indexed expires_at only, so this stays a cheap index range
    # scan on the unauthenticated start path. Consumed/denied rows are short-
    # lived and get swept once their (unchanged) expiry passes.
    from(authorization in ClientAuthorization, where: authorization.expires_at <= ^now)
    |> Repo.delete_all()

    :ok
  rescue
    _error -> :ok
  end

  defp transition(id, callback) do
    Repo.transaction(fn ->
      authorization =
        Repo.one(
          from candidate in ClientAuthorization,
            where: candidate.id == ^id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:not_found)

      case callback.(authorization) do
        {:ok, updated} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp valid_device_code?(<<"trkd_", encoded::binary-size(43)>>),
    do: encoded =~ ~r/^[A-Za-z0-9_-]+$/

  defp valid_device_code?(_device_code), do: false

  defp normalize_user_code(code) do
    code
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z2-7]/, "")
  end

  @doc "Formats a user code as `XXXX-YYYY` for display in the terminal and browser."
  def display_user_code(code) do
    normalized = normalize_user_code(code)
    String.slice(normalized, 0, 4) <> "-" <> String.slice(normalized, 4, 4)
  end

  defp random_user_code, do: :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false)

  defp random_url_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp token_hash(token), do: AccountToken.hash_token(token)
end
