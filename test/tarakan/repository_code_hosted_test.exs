defmodule Tarakan.RepositoryCodeHostedTest do
  use Tarakan.DataCase, async: false

  import Tarakan.AccountsFixtures

  alias Tarakan.Accounts
  alias Tarakan.HostedRepositories
  alias Tarakan.HostedRepositories.Storage
  alias Tarakan.RepositoryCode
  alias Tarakan.RepositoryCode.File, as: CodeFile
  alias Tarakan.RepositoryCode.Tree

  setup do
    on_exit(fn ->
      File.rm_rf(Application.fetch_env!(:tarakan, Tarakan.HostedRepositories)[:root])
    end)

    Tarakan.RepositoryCode.Cache.clear()

    account = account_fixture()
    scope = Accounts.scope_for_account(account)
    {:ok, repository} = HostedRepositories.create(scope, %{"name" => "browsable"})
    %{repository: repository}
  end

  defp push_fixture_commit(repository, tmp_dir) do
    work = Path.join(tmp_dir, "work")

    {_output, 0} =
      System.cmd("git", ["clone", "--quiet", Storage.dir(repository), work],
        stderr_to_stdout: true
      )

    File.write!(Path.join(work, "README.md"), "# Hosted\n")
    File.mkdir_p!(Path.join(work, "lib"))
    File.write!(Path.join(work, "lib/code.ex"), "IO.puts(:ok)\n")

    env = [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]

    {_output, 0} = System.cmd("git", ["-C", work, "add", "."], env: env)
    {_output, 0} = System.cmd("git", ["-C", work, "commit", "--quiet", "-m", "seed"], env: env)

    {_output, 0} =
      System.cmd("git", ["-C", work, "push", "--quiet", "origin", "HEAD"],
        env: env,
        stderr_to_stdout: true
      )

    {sha, 0} = System.cmd("git", ["-C", work, "rev-parse", "HEAD"])
    String.trim(sha)
  end

  @tag :tmp_dir
  test "browses a hosted repository from local storage", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    sha = push_fixture_commit(repository, tmp_dir)

    assert {:ok, ^sha} = RepositoryCode.resolve_default_commit(repository)

    assert {:ok, %Tree{} = tree} = RepositoryCode.browse(repository, sha, nil)
    paths = Enum.map(tree.entries, & &1.path)
    assert "README.md" in paths
    assert "lib" in paths

    assert {:ok, %CodeFile{} = file} = RepositoryCode.browse(repository, sha, "README.md")
    assert file.content == "# Hosted\n"

    assert {:ok, %Tree{} = subtree} = RepositoryCode.browse(repository, sha, "lib")
    assert Enum.map(subtree.entries, & &1.path) == ["lib/code.ex"]

    assert {:error, :not_found} =
             RepositoryCode.browse(repository, sha, "missing.txt")
  end

  test "an empty hosted repository reports empty_repository", %{repository: repository} do
    assert {:error, :empty_repository} = RepositoryCode.resolve_default_commit(repository)
  end

  test "unknown commits in a hosted repository are not found", %{repository: repository} do
    unknown = String.duplicate("b", 40)
    assert {:error, :not_found} = RepositoryCode.browse(repository, unknown, nil)
  end
end
