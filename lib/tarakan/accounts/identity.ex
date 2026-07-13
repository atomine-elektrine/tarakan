defmodule Tarakan.Accounts.Identity do
  @moduledoc """
  An external forge identity linked to a Tarakan account.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account

  schema "identities" do
    field :provider, :string
    field :provider_uid, :string
    field :provider_login, :string
    field :name, :string
    field :avatar_url, :string
    field :profile_url, :string
    field :last_login_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def provider_changeset(identity, account, provider, profile) do
    identity
    |> change()
    |> put_change(:provider, to_string(provider))
    |> put_change(:provider_uid, to_string(profile.provider_uid))
    |> put_change(:provider_login, profile.provider_login)
    |> put_change(:name, profile.name)
    |> put_change(:avatar_url, profile.avatar_url)
    |> put_change(:profile_url, profile.profile_url)
    |> put_change(:last_login_at, DateTime.utc_now())
    |> put_change(:account_id, account.id)
    |> validate_required([
      :provider,
      :provider_uid,
      :provider_login,
      :profile_url,
      :last_login_at,
      :account_id
    ])
    |> unique_constraint([:provider, :provider_uid])
    |> unique_constraint([:provider, :provider_login])
  end
end
