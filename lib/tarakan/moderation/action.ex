defmodule Tarakan.Moderation.Action do
  @moduledoc "An immutable, reasoned moderator action."

  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(assign quarantine redact restore resolve dismiss suspend_account restore_account appeal_upheld appeal_denied)

  schema "moderation_actions" do
    field :action, :string
    field :reason, :string
    field :metadata, :map, default: %{}

    belongs_to :moderation_case, Tarakan.Moderation.Case
    belongs_to :actor, Tarakan.Accounts.Account

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def actions, do: @actions

  def changeset(action, attrs) do
    action
    |> cast(attrs, [:action, :reason, :metadata])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:action, :reason])
    |> validate_inclusion(:action, @actions)
    |> validate_length(:reason, min: 10, max: 2_000)
    |> check_constraint(:action, name: :moderation_actions_action_must_be_valid)
  end
end
