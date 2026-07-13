defmodule Tarakan.Accounts.AccountToken do
  use Ecto.Schema
  import Ecto.Query
  alias Tarakan.Accounts.AccountToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 60

  schema "accounts_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :account, Tarakan.Accounts.Account

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a session token.

  The raw token is returned for the signed cookie/session; only its SHA-256
  hash is stored so a database read alone cannot hijack sessions.
  """
  def build_session_token(account) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = account.authenticated_at || DateTime.utc_now(:second)

    {token,
     %AccountToken{
       token: hash_token(token),
       context: "session",
       account_id: account.id,
       authenticated_at: dt
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the account found by the token, if any, along with the token's creation time.

  The token is valid if its hash matches the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) when is_binary(token) do
    query =
      from token in by_token_and_context_query(hash_token(token), "session"),
        join: account in assoc(token, :account),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{account | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  def verify_session_token_query(_token), do: :error

  @doc "SHA-256 of a raw session token (for storage and lookup)."
  def hash_token(token) when is_binary(token), do: :crypto.hash(@hash_algorithm, token)

  @doc """
  Builds a token and its hash to be delivered to the account's email.

  The non-hashed token is sent to the account email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the account changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(account, context) do
    build_hashed_token(account, context, account.email)
  end

  defp build_hashed_token(account, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %AccountToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       account_id: account.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{account, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks whether the token has expired. The context
  of a magic link token is always "login".
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: account in assoc(token, :account),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == account.email,
            select: {account, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the account_token found by the token, if any.

  This is used to validate requests to change the account
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from AccountToken, where: [token: ^token, context: ^context]
  end
end
