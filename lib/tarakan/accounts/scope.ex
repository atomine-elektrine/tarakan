defmodule Tarakan.Accounts.Scope do
  @moduledoc """
  An authorization snapshot for the caller behind a request.

  The account remains available for compatibility with Phoenix's generated
  authentication code. Authorization code should prefer the copied standing,
  role, trust, repository relationship, and credential fields on the scope.
  """

  alias Tarakan.Accounts.Account

  defstruct account: nil,
            account_id: nil,
            account_state: nil,
            platform_role: nil,
            trust_tier: nil,
            repository_memberships: %{},
            token_id: nil,
            token_scopes: nil,
            token_repository_id: nil,
            authentication_method: nil

  @type t :: %__MODULE__{
          account: Account.t() | nil,
          account_id: integer() | nil,
          account_state: String.t() | nil,
          platform_role: String.t() | nil,
          trust_tier: String.t() | nil,
          repository_memberships: %{optional(integer()) => map()},
          token_id: integer() | nil,
          token_scopes: MapSet.t(String.t()) | nil,
          token_repository_id: integer() | nil,
          authentication_method: atom() | String.t() | nil
        }

  @doc """
  Creates a scope for an account.

  `token_scopes: nil` represents a browser session or trusted system scope.
  API credential scopes fail closed when the grant list is absent. Supplying an
  empty list represents a credential with no grants.
  Repository memberships may be a list of membership structs or a map keyed
  by repository id.

  Returns nil if no account is given.
  """
  def for_account(account, opts \\ [])

  def for_account(%Account{} = account, opts) do
    %__MODULE__{
      account: account,
      account_id: account.id,
      account_state: account.state,
      platform_role: account.platform_role,
      trust_tier: account.trust_tier,
      repository_memberships:
        opts |> option(:repository_memberships, []) |> normalize_memberships(),
      token_id: option(opts, :token_id),
      token_scopes: opts |> option(:token_scopes) |> normalize_token_scopes(),
      token_repository_id: option(opts, :token_repository_id),
      authentication_method: option(opts, :authentication_method, :session)
    }
  end

  def for_account(nil, _opts), do: nil

  @doc "Creates an explicit scope for trusted background maintenance."
  def for_system(opts \\ []) do
    %__MODULE__{
      account_state: "active",
      platform_role: "system",
      trust_tier: "reviewer",
      token_scopes: nil,
      token_repository_id: option(opts, :token_repository_id),
      authentication_method: :system
    }
  end

  @doc "Adds repository relationships to an existing scope."
  def put_repository_memberships(%__MODULE__{} = scope, memberships) do
    %{scope | repository_memberships: normalize_memberships(memberships)}
  end

  @doc "Returns the relationship snapshot for a repository, if one exists."
  def repository_membership(%__MODULE__{} = scope, repository_or_id) do
    with repository_id when is_integer(repository_id) <- repository_id(repository_or_id) do
      Map.get(scope.repository_memberships, repository_id)
    else
      _other -> nil
    end
  end

  def repository_membership(_scope, _repository_or_id), do: nil

  @doc "Whether the caller has a verified repository role."
  def repository_role?(scope, repository_or_id, roles) do
    roles = List.wrap(roles) |> Enum.map(&to_string/1)

    case repository_membership(scope, repository_or_id) do
      %{status: "verified", role: role} -> role in roles
      %{"status" => "verified", "role" => role} -> role in roles
      _other -> false
    end
  end

  @doc "Whether an explicitly scoped credential carries at least one grant."
  def token_scope?(
        %__MODULE__{token_scopes: nil, authentication_method: method},
        _required
      )
      when method in [:session, :system, :ssh_key, "session", "system", "ssh_key"],
      do: true

  def token_scope?(%__MODULE__{token_scopes: nil}, _required), do: false

  def token_scope?(%__MODULE__{token_scopes: scopes}, required) do
    required = List.wrap(required) |> Enum.map(&to_string/1)
    MapSet.member?(scopes, "*") or Enum.any?(required, &MapSet.member?(scopes, &1))
  end

  def token_scope?(_scope, _required), do: false

  defp normalize_memberships(memberships)
       when is_map(memberships) and not is_struct(memberships) do
    memberships
  end

  defp normalize_memberships(memberships) do
    memberships
    |> List.wrap()
    |> Enum.reduce(%{}, fn membership, acc ->
      case membership_repository_id(membership) do
        repository_id when is_integer(repository_id) -> Map.put(acc, repository_id, membership)
        _other -> acc
      end
    end)
  end

  defp normalize_token_scopes(nil), do: nil
  defp normalize_token_scopes(%MapSet{} = scopes), do: scopes

  defp normalize_token_scopes(scopes) do
    scopes
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp membership_repository_id(%{repository_id: repository_id}), do: repository_id
  defp membership_repository_id(%{"repository_id" => repository_id}), do: repository_id
  defp membership_repository_id(_membership), do: nil

  defp repository_id(repository_id) when is_integer(repository_id), do: repository_id
  defp repository_id(%{id: repository_id}) when is_integer(repository_id), do: repository_id

  defp repository_id(%{repository_id: repository_id}) when is_integer(repository_id),
    do: repository_id

  defp repository_id(_repository), do: nil

  defp option(opts, key, default \\ nil)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
end
