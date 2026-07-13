defmodule Tarakan.Git.LocalTest do
  use ExUnit.Case, async: true

  alias Tarakan.Git.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    bare = Path.join(tmp_dir, "fixture.git")
    work = Path.join(tmp_dir, "work")

    {_output, 0} = System.cmd("git", ["init", "--bare", "--quiet", bare])
    {_output, 0} = System.cmd("git", ["clone", "--quiet", bare, work], stderr_to_stdout: true)

    File.write!(Path.join(work, "README.md"), "# Fixture\n")
    File.mkdir_p!(Path.join(work, "lib"))
    File.write!(Path.join(work, "lib/app.ex"), "defmodule App do\nend\n")

    git_in_work = fn args ->
      {_output, 0} =
        System.cmd("git", ["-C", work | args],
          stderr_to_stdout: true,
          env: [
            {"GIT_AUTHOR_NAME", "t"},
            {"GIT_AUTHOR_EMAIL", "t@example.com"},
            {"GIT_COMMITTER_NAME", "t"},
            {"GIT_COMMITTER_EMAIL", "t@example.com"}
          ]
        )
    end

    git_in_work.(["add", "."])
    git_in_work.(["commit", "--quiet", "-m", "initial"])
    git_in_work.(["push", "--quiet", "origin", "HEAD"])

    {sha, 0} = System.cmd("git", ["-C", work, "rev-parse", "HEAD"])
    %{bare: bare, sha: String.trim(sha)}
  end

  test "reads a commit, tree, and blob from a bare repository", %{bare: bare, sha: sha} do
    assert Local.has_commit?(bare, sha)

    assert {:ok, commit} = Local.read_commit(bare, sha)
    assert commit.sha == sha
    assert %DateTime{} = commit.committed_at

    assert {:ok, tree} = Local.read_tree(bare, commit.tree_sha, false)
    refute tree.truncated
    paths = Enum.map(tree.entries, & &1.path)
    assert "README.md" in paths
    assert "lib" in paths

    readme = Enum.find(tree.entries, &(&1.path == "README.md"))
    assert readme.type == "blob"
    assert {:ok, blob} = Local.read_blob(bare, readme.sha)
    assert blob.content == "# Fixture\n"
    assert blob.size == byte_size("# Fixture\n")
  end

  test "recursive tree includes nested entries", %{bare: bare, sha: sha} do
    {:ok, commit} = Local.read_commit(bare, sha)
    assert {:ok, tree} = Local.read_tree(bare, commit.tree_sha, true)
    assert Enum.any?(tree.entries, &(&1.path == "lib/app.ex"))
  end

  test "resolves HEAD to branch and sha", %{bare: bare, sha: sha} do
    assert {:ok, %{branch: branch, sha: ^sha}} = Local.head_commit(bare)
    assert branch in ["main", "master"]
    assert {:ok, branches} = Local.branches(bare)
    assert branch in branches
  end

  test "unborn HEAD reports empty", %{tmp_dir: tmp_dir} do
    empty = Path.join(tmp_dir, "empty.git")
    {_output, 0} = System.cmd("git", ["init", "--bare", "--quiet", empty])
    assert Local.head_commit(empty) == :empty
  end

  test "misses on unknown objects and missing directories", %{bare: bare, tmp_dir: tmp_dir} do
    unknown = String.duplicate("a", 40)
    assert Local.read_commit(bare, unknown) == :miss
    assert Local.read_blob(bare, unknown) == :miss
    assert Local.read_commit(Path.join(tmp_dir, "nope.git"), unknown) == :miss
    refute Local.has_commit?(bare, "not-a-sha")
  end

  test "read_blob enforces the byte cap", %{bare: bare, sha: sha} do
    {:ok, commit} = Local.read_commit(bare, sha)
    {:ok, tree} = Local.read_tree(bare, commit.tree_sha, false)
    readme = Enum.find(tree.entries, &(&1.path == "README.md"))
    assert Local.read_blob(bare, readme.sha, 3) == :miss
  end
end
