defmodule Tarakan.RepositoryMirrorTest do
  use Tarakan.DataCase, async: false
  use Oban.Testing, repo: Tarakan.Repo

  alias Tarakan.GitHubBulkStub
  alias Tarakan.RepositoryCode
  alias Tarakan.RepositoryCode.{Cache, File, InstrumentedGitHubClient}
  alias Tarakan.RepositoryMirror
  alias Tarakan.Sync.{MirrorRepository, RepositorySweepBatch}

  import Tarakan.ScansFixtures

  @moduletag :tmp_dir
  @codex_github_id 95_959_834
  @readme "# Codex\n"

  setup %{tmp_dir: tmp_dir} do
    Cache.clear()

    origin = Path.join(tmp_dir, "origins/openai/codex")
    shas = build_origin!(origin)

    previous = Application.get_env(:tarakan, RepositoryMirror, [])

    Application.put_env(:tarakan, RepositoryMirror,
      enabled: true,
      root: Path.join(tmp_dir, "mirrors"),
      remote_url_template: "file://#{tmp_dir}/origins/:owner/:name/.git",
      fetch_timeout_seconds: 60
    )

    on_exit(fn -> Application.put_env(:tarakan, RepositoryMirror, previous) end)

    %{repository: github_repository_fixture(), shas: shas}
  end

  defp build_origin!(dir) do
    Elixir.File.mkdir_p!(Path.join(dir, "lib"))
    Elixir.File.mkdir_p!(Path.join(dir, "vendor"))
    Elixir.File.write!(Path.join(dir, "README.md"), @readme)
    Elixir.File.write!(Path.join(dir, "lib/codex.ex"), "defmodule Codex do\nend\n")
    Elixir.File.write!(Path.join(dir, "vendor/big.bin"), :crypto.strong_rand_bytes(600_000))

    git!(dir, ["init", "--quiet", "."])
    git!(dir, ["config", "user.email", "test@tarakan.lol"])
    git!(dir, ["config", "user.name", "Tarakan Test"])
    git!(dir, ["config", "uploadpack.allowFilter", "true"])
    git!(dir, ["config", "uploadpack.allowAnySHA1InWant", "true"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", "pinned"])

    %{
      commit: git!(dir, ["rev-parse", "HEAD"]),
      root_tree: git!(dir, ["rev-parse", "HEAD^{tree}"]),
      vendor_tree: git!(dir, ["rev-parse", "HEAD:vendor"]),
      readme_blob: git!(dir, ["rev-parse", "HEAD:README.md"]),
      big_blob: git!(dir, ["rev-parse", "HEAD:vendor/big.bin"])
    }
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp mirror!(repository, shas) do
    assert :ok =
             perform_job(MirrorRepository, %{
               "repository_id" => repository.id,
               "commit_sha" => shas.commit
             })
  end

  test "worker mirrors the pinned commit into a bare repository", %{
    repository: repository,
    shas: shas
  } do
    refute RepositoryMirror.has_commit?(@codex_github_id, shas.commit)

    mirror!(repository, shas)

    assert RepositoryMirror.has_commit?(@codex_github_id, shas.commit)
    # Re-running is a no-op, not a failure.
    mirror!(repository, shas)
  end

  test "mirrored objects read back in the REST client's shapes", %{
    repository: repository,
    shas: shas
  } do
    mirror!(repository, shas)

    assert {:ok, %{sha: commit_sha, tree_sha: tree_sha, committed_at: %DateTime{}}} =
             RepositoryMirror.read_commit(@codex_github_id, shas.commit)

    assert commit_sha == shas.commit
    assert tree_sha == shas.root_tree

    assert {:ok, %{sha: _, truncated: false, entries: entries}} =
             RepositoryMirror.read_tree(@codex_github_id, shas.root_tree, false)

    assert %{type: "blob", size: 8} = Enum.find(entries, &(&1.path == "README.md"))
    assert %{type: "tree", size: nil} = Enum.find(entries, &(&1.path == "lib"))

    assert {:ok, %{size: 8, content: @readme}} =
             RepositoryMirror.read_blob(@codex_github_id, shas.readme_blob)
  end

  test "oversized blobs stay unmirrored (no REST fill-in)", %{
    repository: repository,
    shas: shas
  } do
    mirror!(repository, shas)

    # The 600KB blob exceeded --filter=blob:limit and was never fetched.
    assert :miss = RepositoryMirror.read_blob(@codex_github_id, shas.big_blob)
    # Its directory listing has no local size, so the whole tree stays a miss.
    assert :miss = RepositoryMirror.read_tree(@codex_github_id, shas.vendor_tree, false)
  end

  test "browse serves a mirrored commit without any API object calls", %{
    repository: repository,
    shas: shas
  } do
    mirror!(repository, shas)

    start_supervised!(InstrumentedGitHubClient)
    previous = Application.fetch_env!(:tarakan, :github_client)
    Application.put_env(:tarakan, :github_client, InstrumentedGitHubClient)
    on_exit(fn -> Application.put_env(:tarakan, :github_client, previous) end)

    assert {:ok, %File{content: @readme}} =
             RepositoryCode.browse(repository, shas.commit, "README.md")

    assert InstrumentedGitHubClient.count(:commit) == 0
    assert InstrumentedGitHubClient.count(:tree) == 0
    assert InstrumentedGitHubClient.count(:blob) == 0
    # Browse no longer requires REST identity when the mirror has the objects.
    assert InstrumentedGitHubClient.count(:repository) == 0
  end

  test "browsing an unmirrored commit fetches via git without REST", %{
    repository: repository,
    shas: shas
  } do
    refute RepositoryMirror.has_commit?(@codex_github_id, shas.commit)

    start_supervised!(InstrumentedGitHubClient)
    previous = Application.fetch_env!(:tarakan, :github_client)
    Application.put_env(:tarakan, :github_client, InstrumentedGitHubClient)
    on_exit(fn -> Application.put_env(:tarakan, :github_client, previous) end)

    assert {:ok, %File{content: @readme}} =
             RepositoryCode.browse(repository, shas.commit, "README.md")

    assert RepositoryMirror.has_commit?(@codex_github_id, shas.commit)
    assert InstrumentedGitHubClient.count(:commit) == 0
    assert InstrumentedGitHubClient.count(:tree) == 0
    assert InstrumentedGitHubClient.count(:blob) == 0
    assert InstrumentedGitHubClient.count(:repository) == 0
  end

  test "unknown remote commit is unavailable and never hits REST", %{
    repository: repository
  } do
    commit_sha = String.duplicate("8", 40)

    start_supervised!(InstrumentedGitHubClient)
    previous = Application.fetch_env!(:tarakan, :github_client)
    Application.put_env(:tarakan, :github_client, InstrumentedGitHubClient)
    on_exit(fn -> Application.put_env(:tarakan, :github_client, previous) end)

    assert {:error, :unavailable} =
             RepositoryCode.browse(repository, commit_sha, "README.md")

    assert InstrumentedGitHubClient.count(:commit) == 0
    assert InstrumentedGitHubClient.count(:tree) == 0
    assert InstrumentedGitHubClient.count(:blob) == 0
    assert InstrumentedGitHubClient.count(:repository) == 0
  end

  test "sweep eviction removes the mirror when the repository goes private", %{
    repository: repository,
    shas: shas
  } do
    mirror!(repository, shas)
    assert Elixir.File.dir?(RepositoryMirror.repository_dir(@codex_github_id))

    GitHubBulkStub.put_response(repository.node_id, :not_public)

    assert :ok =
             perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})

    refute Elixir.File.dir?(RepositoryMirror.repository_dir(@codex_github_id))
  end

  test "worker snoozes when the git remote cannot be fetched" do
    hidden =
      Repo.insert!(%Tarakan.Repositories.Repository{
        host: "github.com",
        owner: "private",
        name: "repository",
        canonical_url: "https://github.com/private/repository",
        github_id: 12_345,
        default_branch: "main",
        last_synced_at: DateTime.utc_now()
      })

    # Mirror worker no longer uses REST identity; a bad/missing remote is a soft retry.
    assert {:snooze, _seconds} =
             perform_job(MirrorRepository, %{
               "repository_id" => hidden.id,
               "commit_sha" => String.duplicate("8", 40)
             })
  end
end
