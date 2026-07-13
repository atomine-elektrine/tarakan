defmodule Tarakan.HostedRepositoriesTest do
  use Tarakan.DataCase, async: false

  import Tarakan.AccountsFixtures

  alias Tarakan.Accounts
  alias Tarakan.Audit.Event
  alias Tarakan.HostedRepositories
  alias Tarakan.HostedRepositories.Storage
  alias Tarakan.Repositories
  alias Tarakan.Repositories.RepositoryMembership

  setup do
    on_exit(fn ->
      File.rm_rf(Application.fetch_env!(:tarakan, Tarakan.HostedRepositories)[:root])
    end)

    account = account_fixture()
    %{account: account, scope: Accounts.scope_for_account(account)}
  end

  describe "create/2" do
    test "creates a listed repository with storage and a steward membership", %{
      account: account,
      scope: scope
    } do
      assert {:ok, repository} = HostedRepositories.create(scope, %{"name" => "my-project"})

      assert repository.host == "tarakan.lol"
      assert repository.owner == account.handle
      assert repository.name == "my-project"
      assert repository.listing_status == "listed"
      assert repository.github_id == nil
      assert repository.canonical_url == "https://tarakan.lol/#{account.handle}/my-project"
      assert repository.submitted_by_id == account.id

      assert Storage.exists?(repository)

      config = File.read!(Path.join(Storage.dir(repository), "config"))
      assert config =~ "bare = true"
      assert config =~ "fsckObjects = true"
      assert config =~ "hooksPath = /dev/null"
      assert config =~ "maxInputSize = 262144000"

      membership = Repo.get_by!(RepositoryMembership, repository_id: repository.id)
      assert membership.account_id == account.id
      assert membership.role == "steward"
      assert membership.status == "verified"

      event = Repo.get_by!(Event, action: "hosted_repository_created")
      assert event.repository_id == repository.id
      assert event.actor_id == account.id
    end

    test "is registered under the tarakan host for lookup", %{account: account, scope: scope} do
      {:ok, repository} = HostedRepositories.create(scope, %{"name" => "findable"})

      assert HostedRepositories.resolve(account.handle, "findable").id == repository.id
      assert Repositories.get_repository("tarakan.lol", account.handle, "findable")
      assert HostedRepositories.hosted?(repository)
    end

    test "rejects invalid names", %{scope: scope} do
      for name <- ["", "has space", "trap.git", ".hidden", "..", "a/b"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 HostedRepositories.create(scope, %{"name" => name})

        assert changeset.errors[:name] != nil
      end
    end

    test "downcases names", %{scope: scope} do
      assert {:ok, repository} = HostedRepositories.create(scope, %{"name" => "MyProject"})
      assert repository.name == "myproject"
    end

    test "rejects duplicate names for the same owner", %{scope: scope} do
      assert {:ok, _repository} = HostedRepositories.create(scope, %{"name" => "dupe"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               HostedRepositories.create(scope, %{"name" => "dupe"})

      assert Enum.any?(
               Keyword.values(changeset.errors),
               fn {message, _meta} -> message == "is already one of your repositories" end
             )
    end

    test "denies suspended accounts", %{account: account, scope: scope} do
      account
      |> Ecto.Changeset.change(state: "suspended")
      |> Repo.update!()

      assert {:error, :unauthorized} = HostedRepositories.create(scope, %{"name" => "nope"})
    end

    test "enforces the daily registration quota", %{scope: scope} do
      for index <- 1..5 do
        assert {:ok, _repository} =
                 HostedRepositories.create(scope, %{"name" => "repo-#{index}"})
      end

      assert {:error, :registration_limit} =
               HostedRepositories.create(scope, %{"name" => "repo-6"})
    end
  end

  describe "delete/2" do
    test "steward deletes the record and storage", %{account: account, scope: scope} do
      {:ok, repository} = HostedRepositories.create(scope, %{"name" => "doomed"})
      assert Storage.exists?(repository)

      scope = Accounts.scope_for_account(Repo.reload!(account))
      assert {:ok, _deleted} = HostedRepositories.delete(scope, repository)

      refute Repo.get(Tarakan.Repositories.Repository, repository.id)
      refute Storage.exists?(repository)

      event = Repo.get_by!(Event, action: "hosted_repository_deleted")
      assert event.repository_id == nil
      assert event.metadata["name"] == "doomed"
    end

    test "non-steward cannot delete", %{scope: scope} do
      {:ok, repository} = HostedRepositories.create(scope, %{"name" => "keep"})

      other = account_fixture()
      other_scope = Accounts.scope_for_account(other)

      assert {:error, :unauthorized} = HostedRepositories.delete(other_scope, repository)
      assert Repo.get(Tarakan.Repositories.Repository, repository.id)
      assert Storage.exists?(repository)
    end
  end
end
