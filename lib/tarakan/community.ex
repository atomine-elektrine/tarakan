defmodule Tarakan.Community do
  @moduledoc """
  Live public conversation on the registry.

  Shouts are deliberately small, plain-text, public-at-creation messages. They
  never affect finding status or reputation. Posting requires an account in
  good standing and is rate-limited; moderation leaves an auditable placeholder.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit
  alias Tarakan.Community.Shout
  alias Tarakan.Policy
  alias Tarakan.RateLimiter
  alias Tarakan.Repo

  @topic "community:shoutbox"
  @rate_limit 6
  @rate_window_seconds 60

  @doc "Subscribes to new and moderated shoutbox messages."
  def subscribe, do: Phoenix.PubSub.subscribe(Tarakan.PubSub, @topic)

  @doc "Builds a shout changeset for forms."
  def change_shout(attrs \\ %{}), do: Shout.changeset(%Shout{}, attrs)

  @doc "Lists the newest public shoutbox messages, newest first."
  def list_shouts(scope, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 40) |> min(100) |> max(1)

    Shout
    |> order_by([shout], desc: shout.inserted_at, desc: shout.id)
    |> limit(^limit)
    |> preload(:account)
    |> Repo.all()
    |> Enum.map(&redact_removed(&1, scope))
  end

  @doc "Posts a short public message."
  def create_shout(%Scope{account: %Account{} = account} = scope, attrs) do
    Multi.new()
    |> Multi.run(:authorization, fn _repo, _changes ->
      case authorize_post(scope) do
        :ok -> {:ok, scope}
        error -> error
      end
    end)
    |> Multi.insert(:shout, fn _changes ->
      %Shout{account_id: account.id}
      |> Shout.changeset(attrs)
    end)
    |> Multi.insert(:audit, fn %{shout: shout} ->
      Audit.event_changeset(scope, :registry_shout_posted, shout)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{shout: shout}} ->
        shout = Repo.preload(shout, :account)
        broadcast({:shout_posted, shout})
        {:ok, shout}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def create_shout(_scope, _attrs), do: {:error, :unauthorized}

  @doc "Removes a shout from public view while retaining its audit record."
  def remove_shout(%Scope{account: %Account{} = account} = scope, %Shout{} = shout, attrs) do
    Multi.new()
    |> Multi.run(:authorization, fn _repo, _changes ->
      case Policy.authorize(scope, :moderate_shout, shout) do
        :ok -> {:ok, scope}
        error -> error
      end
    end)
    |> Multi.update(:shout, Shout.removal_changeset(shout, attrs, account.id))
    |> Multi.insert(:audit, fn %{shout: removed} ->
      Audit.event_changeset(scope, :registry_shout_removed, removed, %{
        reason_code: removed.removed_reason
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{shout: removed}} ->
        removed = Repo.preload(removed, :account)
        broadcast({:shout_removed, removed})
        {:ok, removed}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def remove_shout(_scope, _shout, _attrs), do: {:error, :unauthorized}

  @doc "Fetches one shout for moderation."
  def get_shout(id) do
    case Repo.get(Shout, id) do
      nil -> {:error, :not_found}
      shout -> {:ok, Repo.preload(shout, :account)}
    end
  end

  @doc "Whether the current scope may remove shoutbox messages."
  def can_moderate?(%Scope{} = scope), do: Policy.allowed?(scope, :moderate_shout, %Shout{})
  def can_moderate?(_scope), do: false

  defp authorize_post(%Scope{account: %Account{platform_role: role}} = scope)
       when role in ["moderator", "admin"] do
    Policy.authorize(scope, :post_shout)
  end

  defp authorize_post(%Scope{account: %Account{id: account_id}} = scope) do
    with :ok <- Policy.authorize(scope, :post_shout),
         :ok <-
           normalize_rate_result(
             RateLimiter.check({:registry_shout, account_id}, @rate_limit, @rate_window_seconds)
           ) do
      :ok
    end
  end

  defp normalize_rate_result(:ok), do: :ok
  defp normalize_rate_result({:error, _reason, _retry_after}), do: {:error, :rate_limited}

  defp redact_removed(%Shout{removed_at: nil} = shout, _scope), do: shout

  defp redact_removed(%Shout{} = shout, scope) do
    if Policy.allowed?(scope, :moderate_shout, shout), do: shout, else: %{shout | body: nil}
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Tarakan.PubSub, @topic, message)
end
