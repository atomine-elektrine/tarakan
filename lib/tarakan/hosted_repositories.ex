defmodule Tarakan.HostedRepositories do
  @moduledoc """
  Repositories hosted on Tarakan itself.

  A hosted repository is a first-class `Tarakan.Repositories.Repository` whose
  host is `tarakan.lol` and whose owner is the creating account's handle. It
  enters the registry `pending`, exactly like a registered GitHub repository,
  and its creator receives a verified steward membership so pushes are
  authorized from the start.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit
  alias Tarakan.HostedRepositories.Storage
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.{Repository, RepositoryMembership}

  defdelegate hosted?(repository), to: Repository

  @doc "The canonical host for hosted repositories."
  def host, do: Repository.hosted_host()

  @doc "Looks up a hosted repository by owner handle and name."
  def resolve(owner, name) when is_binary(owner) and is_binary(name) do
    Repositories.get_repository(host(), owner, name)
  end

  def resolve(_owner, _name), do: nil

  @doc "Lists an account's hosted repositories, newest first."
  def list_for_account(%Account{handle: handle}) do
    Repository
    |> where([repository], repository.host == ^host() and repository.owner == ^handle)
    |> order_by([repository], desc: repository.inserted_at)
    |> Repo.all()
  end

  @doc """
  Creates a hosted repository owned by the caller.

  The record, the creator's verified steward membership, the audit event, and
  the on-disk bare repository commit or roll back together.
  """
  def create(%Scope{account: %Account{}} = scope, attrs) do
    changeset = Repository.hosted_changeset(%Repository{}, attrs, scope.account.handle)

    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      account =
        repo.one!(
          from account in Account,
            where: account.id == ^scope.account_id,
            lock: "FOR UPDATE"
        )

      fresh_scope =
        case Accounts.refresh_scope_for_account(account, scope) do
          {:ok, fresh_scope} -> fresh_scope
          {:error, reason} -> repo.rollback(reason)
        end

      with :ok <- Policy.authorize(fresh_scope, :register_repository),
           :ok <- Repositories.registration_quota(repo, account) do
        {:ok, %{account: account, scope: fresh_scope}}
      end
    end)
    |> Multi.insert(:repository, fn %{authorization: %{account: account}} ->
      changeset
      |> Ecto.Changeset.put_change(:owner, account.handle)
      |> Ecto.Changeset.put_change(:submitted_by_id, account.id)
    end)
    |> Multi.insert(:membership, fn %{repository: repository, authorization: %{account: account}} ->
      %RepositoryMembership{
        repository_id: repository.id,
        account_id: account.id,
        role: "steward",
        status: "verified",
        verified_at: DateTime.utc_now(:microsecond),
        verified_by_account_id: nil
      }
    end)
    |> Multi.insert(:audit, fn %{authorization: %{scope: fresh_scope}, repository: repository} ->
      Audit.event_changeset(fresh_scope, :hosted_repository_created, repository, %{
        from_state: nil,
        to_state: repository.listing_status
      })
    end)
    |> Multi.run(:storage, fn _repo, %{repository: repository} ->
      case Storage.init_bare(repository) do
        :ok -> {:ok, :initialized}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{repository: repository}} ->
        Repositories.broadcast_registration(repository)
        Tarakan.Activity.broadcast_registration(repository)
        {:ok, repository}

      {:error, :repository, changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def create(_scope, _attrs), do: {:error, :unauthorized}

  @doc """
  Deletes a hosted repository and its storage.

  Restricted to repository stewards and moderators. The record and audit
  event commit first; storage removal follows and is idempotent.
  """
  def delete(%Scope{} = scope, %Repository{} = repository) do
    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      canonical =
        repo.one(
          from candidate in Repository,
            where: candidate.id == ^repository.id,
            lock: "FOR UPDATE"
        )

      account =
        repo.one!(
          from account in Account,
            where: account.id == ^scope.account_id,
            lock: "FOR UPDATE"
        )

      fresh_scope =
        case Accounts.refresh_scope_for_account(account, scope) do
          {:ok, fresh_scope} -> fresh_scope
          {:error, reason} -> repo.rollback(reason)
        end

      cond do
        is_nil(canonical) or not hosted?(canonical) ->
          {:error, :not_found}

        Policy.authorize(fresh_scope, :manage_repository, canonical) != :ok ->
          {:error, :unauthorized}

        true ->
          {:ok, %{repository: canonical, scope: fresh_scope}}
      end
    end)
    |> Multi.insert(:audit, fn %{authorization: %{scope: fresh_scope, repository: canonical}} ->
      Audit.event_changeset(fresh_scope, :hosted_repository_deleted, canonical, %{
        from_state: canonical.listing_status,
        to_state: nil,
        metadata: %{host: canonical.host, owner: canonical.owner, name: canonical.name}
      })
    end)
    |> Multi.delete(:repository, fn %{authorization: %{repository: canonical}} ->
      canonical
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{repository: deleted}} ->
        Storage.destroy(deleted)
        {:ok, deleted}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc "Persists the current on-disk size for quota accounting."
  def update_disk_size(%Repository{} = repository) do
    with {:ok, bytes} <- Storage.disk_size_bytes(repository) do
      repository
      |> Ecto.Changeset.change(disk_size_bytes: bytes)
      |> Repo.update()
    end
  end

  @doc "Whether the repository is over its storage quota."
  def over_quota?(%Repository{disk_size_bytes: bytes}) do
    is_integer(bytes) and bytes > Storage.quota_bytes()
  end
end
