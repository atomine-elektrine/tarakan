defmodule Tarakan.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Identity

  # Reserved names include every top-level route segment: account handles are
  # git-hosting owners at /:owner/:name.git AND hosted repository owners at
  # bare /:owner/:name web paths (router wildcard routes), so a handle that
  # shadows a route would make those URLs ambiguous. Any new top-level route
  # must be added here.
  @reserved_handles ~w(admin api moderator root security support system tarakan www
                       accounts auth findings work requests jobs agents client moderation
                       dev live assets images favicon robots github gitlab codeberg
                       bitbucket repositories hosted fonts leaderboard explore epidemics)
  @states ~w(probation active restricted suspended banned)
  @platform_roles ~w(member moderator admin)
  @trust_tiers ~w(new contributor reviewer)

  schema "accounts" do
    field :handle, :string
    field :display_name, :string
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :reputation, :integer, default: 0
    field :state, :string, default: "probation"
    field :platform_role, :string, default: "member"
    field :trust_tier, :string, default: "new"

    has_many :identities, Identity

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def platform_roles, do: @platform_roles
  def trust_tiers, do: @trust_tiers

  @doc false
  def authorization_changeset(account, attrs) do
    account
    |> cast(attrs, [:state, :platform_role, :trust_tier])
    |> validate_required([:state, :platform_role, :trust_tier])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:platform_role, @platform_roles)
    |> validate_inclusion(:trust_tier, @trust_tiers)
    |> check_constraint(:state, name: :accounts_state_must_be_valid)
    |> check_constraint(:platform_role, name: :accounts_platform_role_must_be_valid)
    |> check_constraint(:trust_tier, name: :accounts_trust_tier_must_be_valid)
  end

  @doc """
  Validates a native Tarakan account with a public handle and email address.

  Account activation is applied programmatically by `Tarakan.Accounts.register_account/1`;
  registration does not require email confirmation.
  """
  def registration_changeset(account, attrs, opts \\ []) do
    account
    |> cast(attrs, [:handle, :email])
    |> validate_handle(opts)
    |> validate_email(opts)
  end

  @doc false
  def external_identity_changeset(account, attrs) do
    now = DateTime.utc_now(:second)

    account
    |> change()
    |> put_change(:handle, attrs.handle)
    |> put_change(:display_name, attrs.display_name)
    |> put_change(:confirmed_at, now)
    |> validate_handle([])
  end

  @doc """
  A account changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(account, attrs, opts \\ []) do
    account
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_handle(changeset, opts) do
    changeset =
      changeset
      |> update_change(:handle, &normalize_handle/1)
      |> validate_required([:handle])
      |> validate_format(:handle, ~r/^[a-z0-9][a-z0-9_-]*$/,
        message: "may contain letters, numbers, underscores, and hyphens"
      )
      |> validate_length(:handle, min: 2, max: 32)
      |> validate_exclusion(
        :handle,
        @reserved_handles,
        message: "is reserved"
      )

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:handle, Tarakan.Repo)
      |> unique_constraint(:handle)
    else
      changeset
    end
  end

  defp normalize_handle(handle) when is_binary(handle) do
    handle |> String.trim() |> String.downcase()
  end

  defp normalize_handle(handle), do: handle

  @doc false
  def reserved_handle?(handle), do: handle in @reserved_handles

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Tarakan.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A account changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(account, attrs, opts \\ []) do
    account
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 15, max: 128)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(account) do
    now = DateTime.utc_now(:second)
    change(account, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no account or the account doesn't have a password, we call
  `Argon2.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Tarakan.Accounts.Account{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end

  @doc """
  Whether the account may establish or continue an authenticated session.

  Suspended and banned accounts are locked out of login, API credentials, and
  SSH — not only mutation policy.
  """
  def access_allowed?(%__MODULE__{state: state}) when state in ["suspended", "banned"], do: false
  def access_allowed?(%__MODULE__{}), do: true
  def access_allowed?(_account), do: false
end
