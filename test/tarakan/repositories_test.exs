defmodule Tarakan.RepositoriesTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit.Event
  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository

  describe "parse_github_repository/1" do
    test "accepts common GitHub repository references" do
      expected = {:ok, %{host: "github.com", owner: "openai", name: "codex"}}

      assert Repositories.parse_github_repository("https://github.com/OpenAI/Codex") == expected
      assert Repositories.parse_github_repository("github.com/openai/codex/") == expected
      assert Repositories.parse_github_repository("openai/codex") == expected
      assert Repositories.parse_github_repository("git@github.com:openai/codex.git") == expected
    end

    test "rejects references that are not GitHub repositories" do
      assert {:error, :invalid_github_repository} =
               Repositories.parse_github_repository("https://gitlab.com/openai/codex")

      assert {:error, :invalid_github_repository} =
               Repositories.parse_github_repository("https://github.com/openai")

      assert {:error, :invalid_github_repository} =
               Repositories.parse_github_repository("https://github.com/openai/codex/issues")
    end
  end

  describe "register_github_repository/2" do
    test "registers a canonical repository once" do
      account = github_account_fixture()

      assert {:ok, repository} =
               Repositories.register_github_repository(
                 "https://github.com/OpenAI/Codex.git",
                 account
               )

      assert repository.owner == "openai"
      assert repository.name == "codex"
      assert repository.canonical_url == "https://github.com/openai/codex"
      assert repository.status == "unscanned"
      assert repository.github_id == 95_959_834
      assert repository.default_branch == "main"
      assert repository.primary_language == "Rust"
      assert repository.stars_count == 42_000
      assert repository.submitted_by_id == account.id

      assert %Event{action: "repository_registered", subject_id: subject_id} =
               Repo.get_by(Event, action: "repository_registered", actor_id: account.id)

      assert subject_id == repository.id

      assert {:ok, same_repository} =
               Repositories.register_github_repository("openai/codex", account)

      assert same_repository.id == repository.id
      assert Repositories.count_repositories() == 1
    end

    test "does not register a repository GitHub cannot verify" do
      account = github_account_fixture()

      assert {:error, :not_found} =
               Repositories.register_github_repository("missing/repository", account)

      assert Repositories.count_repositories() == 0
    end

    test "denies inactive accounts and credentials without repository scope" do
      account = github_account_fixture()

      read_only_scope =
        Scope.for_account(account,
          token_scopes: ["tasks:read"],
          authentication_method: :api_credential
        )

      assert {:error, :unauthorized} =
               Repositories.register_github_repository("openai/codex", read_only_scope)

      banned =
        account
        |> Account.authorization_changeset(%{state: "banned"})
        |> Repo.update!()

      assert {:error, :unauthorized} =
               Repositories.register_github_repository("openai/codex", banned)
    end

    test "limits new accounts to five repository registrations per day" do
      account = github_account_fixture()
      now = DateTime.utc_now()

      for number <- 1..5 do
        Repo.insert!(%Repository{
          host: "github.com",
          owner: "quota-owner-#{number}",
          name: "repository",
          canonical_url: "https://github.com/quota-owner-#{number}/repository",
          github_id: 10_000 + number,
          last_synced_at: now,
          submitted_by_id: account.id
        })
      end

      assert {:error, :registration_limit} =
               Repositories.register_github_repository("openai/codex", account)

      assert Repositories.get_github_repository("openai", "codex") == nil
    end
  end

  describe "search_repositories/2" do
    defp insert_repository!(owner, name, attrs \\ []) do
      Repo.insert!(
        struct!(
          %Repository{
            host: "github.com",
            owner: owner,
            name: name,
            canonical_url: "https://github.com/#{owner}/#{name}",
            github_id: System.unique_integer([:positive]),
            last_synced_at: DateTime.utc_now()
          },
          attrs
        )
      )
    end

    test "matches owner, name, and the combined owner/name form" do
      codex = insert_repository!("openai", "codex")
      cockroach = insert_repository!("cockroachdb", "cockroach")

      assert [%Repository{id: id}] = Repositories.search_repositories("openai/co")
      assert id == codex.id

      assert Repositories.search_repositories("OPENAI") |> Enum.map(& &1.id) == [codex.id]
      assert Repositories.search_repositories("roach") |> Enum.map(& &1.id) == [cockroach.id]

      assert Repositories.search_repositories("co") |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([codex.id, cockroach.id])
    end

    test "ranks name-prefix matches first" do
      suffix = insert_repository!("acme", "libcodex")
      prefix = insert_repository!("acme", "codex-tools")

      assert Repositories.search_repositories("codex") |> Enum.map(& &1.id) ==
               [prefix.id, suffix.id]
    end

    test "only returns listed repositories" do
      insert_repository!("openai", "codex", listing_status: "quarantined")
      insert_repository!("openai", "evals", listing_status: "pending")

      assert Repositories.search_repositories("openai") == []
    end

    test "returns nothing for blank queries" do
      insert_repository!("openai", "codex")

      assert Repositories.search_repositories("") == []
      assert Repositories.search_repositories("   ") == []
      assert Repositories.search_repositories(nil) == []
    end

    test "escapes ilike metacharacters instead of treating them as wildcards" do
      insert_repository!("openai", "codex")
      underscored = insert_repository!("acme", "my_repo")

      assert Repositories.search_repositories("%") == []
      assert Repositories.search_repositories("c_dex") == []
      assert Repositories.search_repositories("\\") == []
      assert Repositories.search_repositories("my_re") |> Enum.map(& &1.id) == [underscored.id]
    end

    test "clamps the limit" do
      for number <- 1..3, do: insert_repository!("bulk-owner-#{number}", "repository")

      assert length(Repositories.search_repositories("bulk-owner", 2)) == 2
      assert length(Repositories.search_repositories("bulk-owner", 0)) == 1
    end
  end
end
