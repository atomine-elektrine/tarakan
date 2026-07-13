defmodule Tarakan.Accounts do
  @moduledoc """
  Provider-neutral Tarakan accounts, credentials, and linked forge identities.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi

  alias Tarakan.Accounts.{
    Account,
    AccountNotifier,
    AccountToken,
    ApiCredential,
    ApiCredentials,
    Identity,
    Scope,
    SshKey
  }

  alias Tarakan.Audit
  alias Tarakan.Repo

  @authorization_topic_prefix "authorization:account:"

  @doc "Subscribes a signed-in LiveView to authorization invalidations."
  def subscribe_authorization(account_id) when is_integer(account_id) do
    Phoenix.PubSub.subscribe(Tarakan.PubSub, authorization_topic(account_id))
  end

  @doc "Invalidates authorization snapshots held by this account's live sessions."
  def broadcast_authorization_changed(account_id) when is_integer(account_id) do
    Phoenix.PubSub.broadcast(
      Tarakan.PubSub,
      authorization_topic(account_id),
      {:authorization_changed, account_id}
    )
  end

  def get_account(nil), do: nil
  def get_account(id) when is_integer(id), do: Repo.get(Account, id)

  def get_account(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed_id, ""} -> get_account(parsed_id)
      _other -> nil
    end
  end

  @doc "Lists up to 100 accounts for the platform administration console."
  def list_accounts_for_admin(%Scope{} = scope, query \\ "") do
    with {:ok, fresh_scope} <- refresh_admin_scope(scope),
         :ok <- Tarakan.Policy.authorize(fresh_scope, :administer) do
      query = query |> to_string() |> String.trim()

      accounts =
        Account
        |> maybe_search_accounts(query)
        |> order_by([account],
          asc:
            fragment(
              "CASE ? WHEN 'admin' THEN 0 WHEN 'moderator' THEN 1 ELSE 2 END",
              account.platform_role
            ),
          asc: account.handle
        )
        |> limit(100)
        |> Repo.all()

      {:ok, accounts}
    end
  end

  @doc "Fetches one account for the platform administration console."
  def get_account_for_admin(%Scope{} = scope, id) do
    with {:ok, fresh_scope} <- refresh_admin_scope(scope),
         :ok <- Tarakan.Policy.authorize(fresh_scope, :administer),
         %Account{} = account <- get_account(id) do
      {:ok, account}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Aggregate account counts for the platform administration console."
  def account_admin_summary(%Scope{} = scope) do
    with {:ok, fresh_scope} <- refresh_admin_scope(scope),
         :ok <- Tarakan.Policy.authorize(fresh_scope, :administer) do
      summary =
        Repo.one(
          from account in Account,
            select: %{
              total: count(account.id),
              admins: count(account.id) |> filter(account.platform_role == "admin"),
              moderators: count(account.id) |> filter(account.platform_role == "moderator"),
              restricted:
                count(account.id)
                |> filter(account.state in ["restricted", "suspended", "banned"])
            }
        )

      {:ok, summary}
    end
  end

  @doc """
  Builds an authorization scope with the account's current repository
  relationships. Credential details may be supplied as `Scope.for_account/2`
  options.
  """
  def scope_for_account(account, opts \\ [])

  def scope_for_account(%Account{} = account, opts) do
    memberships = Tarakan.Repositories.list_account_memberships(account)

    opts =
      if is_list(opts) do
        Keyword.put(opts, :repository_memberships, memberships)
      else
        Map.put(opts, :repository_memberships, memberships)
      end

    Scope.for_account(account, opts)
  end

  def scope_for_account(nil, _opts), do: nil

  @doc "Rebuilds a scope from current account and credential state."
  def refresh_scope_for_account(
        %Account{} = account,
        %Scope{authentication_method: :api_credential, token_id: token_id}
      ) do
    case ApiCredentials.fetch_active(token_id, account.id) do
      {:ok, credential} ->
        {:ok,
         scope_for_account(account,
           token_id: credential.id,
           token_scopes: credential.scopes,
           token_repository_id: credential.repository_id,
           authentication_method: :api_credential
         )}

      :error ->
        {:error, :unauthorized}
    end
  end

  def refresh_scope_for_account(%Account{} = account, %Scope{} = prior_scope) do
    {:ok,
     scope_for_account(account,
       token_id: prior_scope.token_id,
       token_scopes: prior_scope.token_scopes,
       token_repository_id: prior_scope.token_repository_id,
       authentication_method: prior_scope.authentication_method || :session
     )}
  end

  @doc "Updates account standing when the caller is a platform administrator."
  def update_authorization(%Scope{} = scope, %Account{} = account, attrs) do
    result =
      Repo.transaction(fn ->
        caller =
          Repo.one(
            from candidate in Account,
              where: candidate.id == ^scope.account_id,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:unauthorized)

        canonical_account =
          Repo.one(
            from candidate in Account,
              where: candidate.id == ^account.id,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:not_found)

        fresh_scope =
          case refresh_scope_for_account(caller, scope) do
            {:ok, fresh_scope} -> fresh_scope
            {:error, reason} -> Repo.rollback(reason)
          end

        with :ok <-
               Tarakan.Policy.authorize(
                 fresh_scope,
                 :change_account_authorization,
                 canonical_account
               ),
             changeset <- Account.authorization_changeset(canonical_account, attrs),
             :ok <- ensure_active_admin_remains(Repo, canonical_account, changeset),
             {:ok, updated} <- Repo.update(changeset),
             {:ok, _event} <-
               Audit.record(fresh_scope, :account_authorization_updated, updated, %{
                 from_state: canonical_account.state,
                 to_state: updated.state,
                 metadata: %{
                   platform_role: updated.platform_role,
                   trust_tier: updated.trust_tier
                 }
               }) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, updated} = success ->
        _revalidation = Tarakan.Scans.revalidate_account_authority(updated.id)

        if updated.state in ["suspended", "banned"] do
          invalidate_account_access(updated.id, purge_credentials: updated.state == "banned")
        else
          broadcast_authorization_changed(updated.id)
        end

        success

      error ->
        error
    end
  end

  defp refresh_admin_scope(%Scope{account_id: account_id} = prior_scope)
       when is_integer(account_id) do
    case Repo.get(Account, account_id) do
      %Account{} = account -> refresh_scope_for_account(account, prior_scope)
      nil -> {:error, :unauthorized}
    end
  end

  defp refresh_admin_scope(_scope), do: {:error, :unauthorized}

  defp maybe_search_accounts(query, ""), do: query

  defp maybe_search_accounts(query, search) do
    pattern = "%#{search}%"

    where(
      query,
      [account],
      ilike(account.handle, ^pattern) or ilike(account.email, ^pattern) or
        ilike(account.display_name, ^pattern)
    )
  end

  defp ensure_active_admin_remains(repo, canonical_account, changeset) do
    currently_effective? =
      canonical_account.platform_role == "admin" and
        canonical_account.state in ["probation", "active"]

    remains_effective? =
      Ecto.Changeset.get_field(changeset, :platform_role) == "admin" and
        Ecto.Changeset.get_field(changeset, :state) in ["probation", "active"]

    if currently_effective? and not remains_effective? do
      effective_admins =
        repo.all(
          from account in Account,
            where: account.platform_role == "admin" and account.state in ["probation", "active"],
            lock: "FOR UPDATE"
        )

      if length(effective_admins) > 1, do: :ok, else: {:error, :last_admin}
    else
      :ok
    end
  end

  @doc """
  Whether the account may sign in or continue using credentials / SSH keys.
  """
  def access_allowed?(%Account{} = account), do: Account.access_allowed?(account)
  def access_allowed?(_account), do: false

  @doc """
  Contains a suspended or banned account: ends every active session and drops
  connected LiveViews so nothing keeps acting under the old scope.

  API credentials and SSH keys are already refused at authentication time for
  locked accounts (`Account.access_allowed?/1`), so suspension — which is
  reversible — leaves them intact and reinstatement restores access. Pass
  `purge_credentials: true` (used for permanent bans) to also revoke API
  credentials and delete SSH keys.
  """
  def invalidate_account_access(account_id, opts \\ [])

  def invalidate_account_access(account_id, opts) when is_integer(account_id) do
    Repo.delete_all(from token in AccountToken, where: token.account_id == ^account_id)

    if Keyword.get(opts, :purge_credentials, false) do
      Repo.update_all(
        from(credential in ApiCredential,
          where: credential.account_id == ^account_id and is_nil(credential.revoked_at)
        ),
        set: [revoked_at: DateTime.utc_now()]
      )

      Repo.delete_all(from key in SshKey, where: key.account_id == ^account_id)
    end

    broadcast_authorization_changed(account_id)

    # Account-scoped LiveView socket topic (see AccountAuth.put_token_in_session/2).
    TarakanWeb.Endpoint.broadcast(account_sessions_topic(account_id), "disconnect", %{})

    :ok
  end

  def invalidate_account_access(_account_id, _opts), do: {:error, :not_found}

  @doc false
  def account_sessions_topic(account_id) when is_integer(account_id),
    do: "accounts_sessions:#{account_id}"

  def upsert_external_identity(provider, profile, account \\ nil) do
    provider = to_string(provider)
    provider_uid = to_string(profile.provider_uid)

    case Repo.get_by(Identity, provider: provider, provider_uid: provider_uid) do
      nil when is_nil(account) ->
        create_external_identity(provider, profile)

      nil ->
        link_external_identity(account, provider, profile)

      %{account_id: account_id} = identity when is_nil(account) or account_id == account.id ->
        update_external_identity(identity, provider, profile)

      _identity ->
        {:error, :identity_already_linked}
    end
  end

  defp link_external_identity(%Account{} = account, provider, profile) do
    %Identity{}
    |> Identity.provider_changeset(account, provider, profile)
    |> Repo.insert()
    |> case do
      {:ok, _identity} -> {:ok, account}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp create_external_identity(provider, profile) do
    handle = available_handle(profile.provider_login)

    Multi.new()
    |> Multi.insert(
      :account,
      Account.external_identity_changeset(%Account{}, %{
        handle: handle,
        # Provider profile names are retained on the private identity record.
        # They must not silently become a public Tarakan profile field.
        display_name: nil
      })
    )
    |> Multi.insert(:identity, fn %{account: account} ->
      Identity.provider_changeset(%Identity{}, account, provider, profile)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  defp update_external_identity(identity, provider, profile) do
    identity = Repo.preload(identity, :account)

    # Enforce suspension/ban lockout at the shared login chokepoint so every
    # OAuth provider inherits it, rather than relying on each controller to
    # re-check access_allowed? after the upsert.
    if Account.access_allowed?(identity.account) do
      case identity
           |> Identity.provider_changeset(identity.account, provider, profile)
           |> Repo.update() do
        {:ok, _identity} -> {:ok, identity.account}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :account_locked}
    end
  end

  defp available_handle(provider_login) do
    base =
      provider_login
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/, "-")
      |> String.trim("-_")
      |> String.slice(0, 32)
      |> usable_external_handle()

    if Repo.exists?(from account in Account, where: account.handle == ^base) do
      suffix = System.unique_integer([:positive]) |> Integer.to_string(36) |> String.slice(-8, 8)
      String.slice(base, 0, 31 - byte_size(suffix)) <> "-" <> suffix
    else
      base
    end
  end

  defp usable_external_handle(""), do: "forge-id"
  defp usable_external_handle(handle) when byte_size(handle) < 2, do: handle <> "-id"

  defp usable_external_handle(handle) do
    if Account.reserved_handle?(handle), do: String.slice(handle <> "-user", 0, 32), else: handle
  end

  def list_external_identities(%Account{id: account_id}) do
    Identity
    |> where([identity], identity.account_id == ^account_id)
    |> order_by([identity], asc: identity.provider)
    |> Repo.all()
  end

  ## Database getters

  @doc """
  Gets a account by email.

  ## Examples

      iex> get_account_by_email("foo@example.com")
      %Account{}

      iex> get_account_by_email("unknown@example.com")
      nil

  """
  def get_account_by_email(email) when is_binary(email) do
    Repo.get_by(Account, email: email)
  end

  @doc "Gets an account by its public handle."
  def get_account_by_handle(handle) when is_binary(handle) do
    Repo.get_by(Account, handle: String.downcase(handle))
  end

  @doc """
  Gets a account by email and password.

  ## Examples

      iex> get_account_by_email_and_password("foo@example.com", "correct_password")
      %Account{}

      iex> get_account_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_account_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    account = Repo.get_by(Account, email: email)

    cond do
      is_nil(account) or not Account.access_allowed?(account) ->
        Account.valid_password?(nil, password)
        nil

      Account.valid_password?(account, password) ->
        account

      true ->
        nil
    end
  end

  def get_account_by_identifier_and_password(identifier, password)
      when is_binary(identifier) and is_binary(password) do
    identifier = String.trim(identifier)

    account =
      Repo.one(
        from account in Account,
          where: account.handle == ^identifier or account.email == ^identifier
      )

    cond do
      is_nil(account) or not Account.access_allowed?(account) ->
        Account.valid_password?(nil, password)
        nil

      Account.valid_password?(account, password) ->
        account

      true ->
        nil
    end
  end

  @doc """
  Gets a single account.

  Raises `Ecto.NoResultsError` if the Account does not exist.

  ## Examples

      iex> get_account!(123)
      %Account{}

      iex> get_account!(456)
      ** (Ecto.NoResultsError)

  """
  def get_account!(id), do: Repo.get!(Account, id)

  ## Account registration

  @doc """
  Registers a account.

  Prefer `request_registration/2` for browser registration so uniqueness
  conflicts are not revealed to the client. This lower-level function still
  returns changeset uniqueness errors for fixtures and internal callers.

  ## Examples

      iex> register_account(%{field: value})
      {:ok, %Account{}}

      iex> register_account(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_account(attrs) do
    %Account{}
    |> Account.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert()
  end

  @doc """
  Starts email registration without revealing whether an email or handle is taken.

  A newly created account receives a one-time token that the browser can use to
  establish its session immediately. A separate login link is also emailed for
  later use. When the email already belongs to an accessible account, login
  instructions are sent instead of creating a second row. Format and
  reserved-handle errors remain visible.

  Returns:

    * `{:ok, {:created, token}}` — active account created and ready for immediate login
    * `{:ok, :accepted}` — existing email notified with a login link, or a
      uniqueness conflict handled silently
    * `{:error, changeset}` — safe validation errors only (never uniqueness)
  """
  def request_registration(attrs, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    case register_account(attrs) do
      {:ok, account} ->
        _ = deliver_login_instructions(account, magic_link_url_fun)
        {:ok, {:created, issue_registration_login_token(account)}}

      {:error, %Ecto.Changeset{} = changeset} ->
        case registration_error_class(changeset) do
          :uniqueness_only ->
            maybe_notify_existing_registrant(attrs, magic_link_url_fun)
            {:ok, :accepted}

          :validation ->
            {:error, strip_uniqueness_errors(changeset)}
        end
    end
  end

  defp issue_registration_login_token(account) do
    {encoded_token, account_token} = AccountToken.build_email_token(account, "login")
    Repo.insert!(account_token)
    encoded_token
  end

  def change_account_registration(account, attrs \\ %{}, opts \\ []) do
    Account.registration_changeset(account, attrs, opts)
  end

  defp registration_error_class(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, &(not uniqueness_error?(&1))), do: :validation, else: :uniqueness_only
  end

  defp uniqueness_error?({field, {_message, opts}}) when field in [:email, :handle] do
    opts[:validation] == :unsafe_unique or opts[:constraint] == :unique
  end

  defp uniqueness_error?(_error), do: false

  defp strip_uniqueness_errors(%Ecto.Changeset{} = changeset) do
    errors = Enum.reject(changeset.errors, &uniqueness_error?/1)
    # Display-only: uniqueness messages are never returned to the client.
    %{changeset | errors: errors, valid?: false}
  end

  defp maybe_notify_existing_registrant(attrs, magic_link_url_fun) do
    with email when is_binary(email) <- registration_attr(attrs, :email),
         trimmed when trimmed != "" <- String.trim(email),
         %Account{} = account <- get_account_by_email(trimmed),
         true <- access_allowed?(account) do
      deliver_login_instructions(account, magic_link_url_fun)
    else
      _other -> :ok
    end
  end

  defp registration_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp registration_attr(_attrs, _key), do: nil

  ## Settings

  # How long a password / magic-link sign-in counts as "recent" for sensitive UI.
  # Two hours balances a normal work block against stolen-session credential minting.
  @sudo_window_minutes -2 * 60

  @doc """
  Checks whether the account is in sudo mode (recently authenticated).

  Default window is 8 hours after the last password or magic-link sign-in.
  Pass a more negative `minutes` to require a fresher login (e.g. `-20`).
  """
  def sudo_mode?(account, minutes \\ @sudo_window_minutes)

  def sudo_mode?(%Account{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_account, _minutes), do: false

  @doc "Default sudo window in minutes (negative), e.g. -480 for 8 hours."
  def sudo_window_minutes, do: @sudo_window_minutes

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the account email.

  See `Tarakan.Accounts.Account.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_account_email(account)
      %Ecto.Changeset{data: %Account{}}

  """
  def change_account_email(account, attrs \\ %{}, opts \\ []) do
    Account.email_changeset(account, attrs, opts)
  end

  @doc """
  Updates the account email using the given token.

  If the token matches, the account email is updated and the token is deleted.
  """
  def update_account_email(account, token) do
    context = "change:#{account.email}"

    Repo.transact(fn ->
      with {:ok, query} <- AccountToken.verify_change_email_token_query(token, context),
           %AccountToken{sent_to: email} <- Repo.one(query),
           {:ok, account} <- Repo.update(Account.email_changeset(account, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(
               from(AccountToken, where: [account_id: ^account.id, context: ^context])
             ) do
        {:ok, account}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the account password.

  See `Tarakan.Accounts.Account.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_account_password(account)
      %Ecto.Changeset{data: %Account{}}

  """
  def change_account_password(account, attrs \\ %{}, opts \\ []) do
    Account.password_changeset(account, attrs, opts)
  end

  @doc """
  Updates the account password.

  Returns a tuple with the updated account, as well as a list of expired tokens.

  ## Examples

      iex> update_account_password(account, %{password: ...})
      {:ok, {%Account{}, [...]}}

      iex> update_account_password(account, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_account_password(account, attrs) do
    account
    |> Account.password_changeset(attrs)
    |> update_account_and_delete_all_tokens()
  end

  ## API tokens

  @doc """
  Creates a scoped API credential for Tarakan Client and external review harnesses.

  Returns the plaintext token; only its hash is stored, so it cannot be
  retrieved again. Existing credentials remain valid until they expire or are
  individually revoked.
  """
  def create_account_api_token(%Account{} = account) do
    {:ok, token, _credential} = ApiCredentials.create(account)
    token
  end

  @doc """
  Gets the account owning the given API token.

  Prefer `ApiCredentials.authenticate/1` for request authentication because it
  also returns the credential's scopes and repository boundary.
  """
  def fetch_account_by_api_token(token) when is_binary(token) do
    case ApiCredentials.authenticate(token) do
      {:ok, account, _credential} -> {:ok, account}
      _other -> :error
    end
  end

  def fetch_account_by_api_token(_token), do: :error

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_account_session_token(account) do
    {token, account_token} = AccountToken.build_session_token(account)
    Repo.insert!(account_token)
    token
  end

  @doc """
  Gets the account with the given signed token.

  If the token is valid `{account, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_account_by_session_token(token) when is_binary(token) do
    with {:ok, query} <- AccountToken.verify_session_token_query(token),
         {%Account{} = account, inserted_at} <- Repo.one(query),
         true <- Account.access_allowed?(account) do
      {account, inserted_at}
    else
      _other -> nil
    end
  end

  def get_account_by_session_token(_token), do: nil

  @doc """
  Gets the account with the given magic link token.
  """
  def get_account_by_magic_link_token(token) do
    with {:ok, query} <- AccountToken.verify_magic_link_token_query(token),
         {account, _token} <- Repo.one(query) do
      account
    else
      _ -> nil
    end
  end

  @doc """
  Logs the account in by magic link.

  There are two cases to consider:

  1. The account has already confirmed their email. They are logged in
     and the magic link is expired.

  2. A legacy account has no `confirmed_at` timestamp. It is still logged in;
     the timestamp is populated for compatibility and its older tokens are expired.
  """
  def login_account_by_magic_link(token) do
    {:ok, query} = AccountToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      {%Account{confirmed_at: nil} = account, _token} ->
        if Account.access_allowed?(account) do
          account
          |> Account.confirm_changeset()
          |> update_account_and_delete_all_tokens()
        else
          {:error, :not_found}
        end

      {account, token} ->
        if Account.access_allowed?(account) do
          Repo.delete!(token)
          # Routine sign-in for an already-confirmed account: no other token was
          # invalidated, so leave existing sessions (other devices/tabs) connected.
          {:ok, {account, []}}
        else
          {:error, :not_found}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given account.

  ## Examples

      iex> deliver_account_update_email_instructions(account, current_email, &url(~p"/accounts/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_account_update_email_instructions(
        %Account{} = account,
        current_email,
        update_email_url_fun
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, account_token} =
      AccountToken.build_email_token(account, "change:#{current_email}")

    Repo.insert!(account_token)

    AccountNotifier.deliver_update_email_instructions(
      account,
      update_email_url_fun.(encoded_token)
    )
  end

  @doc """
  Delivers the magic link login instructions to the given account.
  """
  def deliver_login_instructions(%Account{} = account, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, account_token} = AccountToken.build_email_token(account, "login")
    Repo.insert!(account_token)
    AccountNotifier.deliver_login_instructions(account, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_account_session_token(token) when is_binary(token) do
    hashed = AccountToken.hash_token(token)
    Repo.delete_all(from(AccountToken, where: [token: ^hashed, context: "session"]))
    :ok
  end

  def delete_account_session_token(_token), do: :ok

  ## Token helper

  defp update_account_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, account} <- Repo.update(changeset) do
        Repo.delete_all(from(t in AccountToken, where: t.account_id == ^account.id))

        Repo.update_all(
          from(credential in ApiCredential,
            where: credential.account_id == ^account.id and is_nil(credential.revoked_at)
          ),
          set: [revoked_at: DateTime.utc_now()]
        )

        # Return account_id for LiveView disconnect (session tokens are hashed).
        {:ok, {account, account.id}}
      end
    end)
  end

  defp authorization_topic(account_id), do: @authorization_topic_prefix <> to_string(account_id)
end
