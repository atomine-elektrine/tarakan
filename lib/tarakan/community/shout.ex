defmodule Tarakan.Community.Shout do
  @moduledoc "A short public message posted to the registry shoutbox."

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account

  schema "registry_shouts" do
    field :body, :string
    field :removed_at, :utc_datetime_usec
    field :removed_reason, :string

    belongs_to :account, Account
    belongs_to :removed_by, Account

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(shout, attrs) do
    shout
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: 280)
  end

  @doc false
  def removal_changeset(shout, attrs, remover_id) do
    shout
    |> cast(attrs, [:removed_reason])
    |> put_change(:removed_at, DateTime.utc_now())
    |> put_change(:removed_by_id, remover_id)
    |> validate_required([:removed_reason])
    |> validate_length(:removed_reason, min: 3, max: 100)
  end
end
