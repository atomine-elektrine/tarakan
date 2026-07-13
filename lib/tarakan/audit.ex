defmodule Tarakan.Audit do
  @moduledoc """
  Append-only audit logging for authorization and workflow state transitions.

  Use `append_to_multi/6` when an event describes a database mutation so the
  state change and its audit record commit atomically.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Tarakan.Accounts.Scope
  alias Tarakan.Audit.Event
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository

  @doc "Builds an audit event changeset without inserting it."
  def event_changeset(scope, action, subject, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.delete("action")
      |> Map.put(:action, to_string(action))
      |> put_subject_defaults(subject)

    %Event{}
    |> Event.append_changeset(attrs)
    |> put_change(:actor_id, scope_account_id(scope))
    |> put_change(:token_id, scope_token_id(scope))
  end

  @doc "Appends one immutable event."
  def record(scope, action, subject, attrs \\ %{}) do
    scope
    |> event_changeset(action, subject, attrs)
    |> Repo.insert()
  end

  @doc "Adds an immutable event insert to an `Ecto.Multi`."
  def append_to_multi(%Multi{} = multi, name, scope, action, subject, attrs \\ %{}) do
    Multi.insert(multi, name, event_changeset(scope, action, subject, attrs))
  end

  @doc "Lists audit history for a repository when the caller may inspect it."
  def list_repository_events(%Scope{} = scope, %Repository{id: repository_id} = repository) do
    with :ok <- Policy.authorize(scope, :view_audit_event, repository) do
      events =
        Event
        |> where([event], event.repository_id == ^repository_id)
        |> order_by([event], asc: event.inserted_at, asc: event.id)
        |> Repo.all()

      {:ok, events}
    end
  end

  defp put_subject_defaults(attrs, nil), do: attrs

  defp put_subject_defaults(attrs, subject) do
    attrs
    |> put_new(:subject_type, subject_type(subject))
    |> put_new(:subject_id, field(subject, :id))
    |> put_new(:repository_id, repository_id(subject))
  end

  defp subject_type(%{__struct__: module}), do: inspect(module)
  defp subject_type(_subject), do: nil

  defp repository_id(%Repository{id: repository_id}), do: repository_id
  defp repository_id(nil), do: nil

  defp repository_id(subject) do
    field(subject, :repository_id) ||
      subject |> field(:repository) |> field(:id) ||
      subject |> field(:task) |> repository_id() ||
      subject |> field(:review_task) |> repository_id()
  end

  defp scope_account_id(%Scope{account_id: account_id}), do: account_id
  defp scope_account_id(_scope), do: nil

  defp scope_token_id(%Scope{token_id: token_id}), do: token_id
  defp scope_token_id(_scope), do: nil

  defp put_new(attrs, key, value) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key)) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp field(nil, _key), do: nil

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, to_string(key))

  defp field(_value, _key), do: nil
end
