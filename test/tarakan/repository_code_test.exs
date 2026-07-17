defmodule Tarakan.RepositoryCodeTest do
  use Tarakan.DataCase, async: false

  alias Tarakan.RepositoryCode
  alias Tarakan.RepositoryCode.InstrumentedGitHubClient
  alias Tarakan.RepositoryCode.{Cache, File, Tree}

  @commit_sha String.duplicate("8", 40)
  @mismatched_sha String.duplicate("a", 40)
  @truncated_commit_sha String.duplicate("c", 40)
  @default_commit_sha String.duplicate("7", 40)

  setup do
    Cache.clear()
    repository = github_repository_fixture()
    %{repository: repository}
  end

  test "browses a commit-pinned root and sorts directories before files", %{
    repository: repository
  } do
    assert {:ok, %Tree{} = tree} = RepositoryCode.browse(repository, @commit_sha, "")

    assert tree.commit_sha == @commit_sha
    assert tree.path == ""
    assert tree.tree_sha == String.duplicate("1", 40)
    refute tree.truncated

    assert [lib | files] = tree.entries
    assert lib.name == "lib"
    assert lib.path == "lib"
    assert lib.type == :tree
    refute Enum.any?(files, &(&1.type == :tree))
  end

  test "follows only server-returned child tree and blob SHAs", %{repository: repository} do
    assert {:ok, %File{} = file} =
             RepositoryCode.browse(repository, @commit_sha, "lib/codex.ex")

    assert file.commit_sha == @commit_sha
    assert file.path == "lib/codex.ex"
    assert file.blob_sha == String.duplicate("4", 40)
    assert file.size == byte_size(file.content)
    assert file.content =~ "defmodule Codex"
  end

  test "supports explicit recursive and non-recursive tree listings", %{repository: repository} do
    assert {:ok, %Tree{} = direct} =
             RepositoryCode.list_tree(repository, @commit_sha, "", recursive: false)

    refute Enum.any?(direct.entries, &(&1.path == "lib/codex.ex"))

    assert {:ok, %Tree{} = recursive} =
             RepositoryCode.list_tree(repository, @commit_sha, "", recursive: true)

    assert Enum.any?(recursive.entries, &(&1.path == "lib/codex.ex"))
    refute recursive.truncated
  end

  test "rejects traversal and commits that are not full SHAs", %{repository: repository} do
    assert {:error, :invalid_path} =
             RepositoryCode.browse(repository, @commit_sha, "lib/../secret")

    assert {:error, :invalid_path} =
             RepositoryCode.browse(repository, @commit_sha, "/etc/passwd")

    assert {:error, :invalid_commit_sha} =
             RepositoryCode.browse(repository, "main", "README.md")
  end

  test "reloads the canonical repository instead of trusting caller fields", %{
    repository: repository
  } do
    tampered = %{repository | owner: "private", name: "repository", github_id: 12_345}

    assert {:ok, %File{content: "# Codex\n"}} =
             RepositoryCode.browse(tampered, @commit_sha, "README.md")
  end

  test "fails closed when the registered public identity no longer matches", %{
    repository: repository
  } do
    repository =
      repository
      |> Ecto.Changeset.change(owner: "private", name: "repository", github_id: 12_345)
      |> Repo.update!()

    assert {:error, :identity_changed} =
             RepositoryCode.browse(repository, @commit_sha, "README.md")
  end

  test "rejects a commit response that does not match the requested SHA", %{
    repository: repository
  } do
    assert {:error, :commit_mismatch} =
             RepositoryCode.browse(repository, @mismatched_sha, "")
  end

  test "rejects oversized blobs from tree metadata before fetching content", %{
    repository: repository
  } do
    assert {:error, :blob_too_large} =
             RepositoryCode.browse(repository, @commit_sha, "large.txt")
  end

  test "rejects binary blob content", %{repository: repository} do
    assert {:error, :binary_blob} =
             RepositoryCode.browse(repository, @commit_sha, "binary.dat")
  end

  test "rejects text that would create more than ten thousand rendered lines", %{
    repository: repository
  } do
    assert {:error, :blob_too_large} =
             RepositoryCode.browse(repository, @commit_sha, "many-lines.txt")
  end

  test "does not follow symlink or submodule entries", %{repository: repository} do
    assert {:error, :unsupported_entry} =
             RepositoryCode.browse(repository, @commit_sha, "source-link")

    assert {:error, :unsupported_entry} =
             RepositoryCode.browse(repository, @commit_sha, "dependency")
  end

  test "rejects a truncated tree instead of presenting an incomplete repository", %{
    repository: repository
  } do
    assert {:error, :tree_truncated} =
             RepositoryCode.browse(repository, @truncated_commit_sha, "")
  end

  test "resolves the current default branch to an exact commit SHA", %{repository: repository} do
    assert {:ok, @default_commit_sha} = RepositoryCode.resolve_default_commit(repository)
    assert {:ok, @default_commit_sha} = RepositoryCode.resolve_entry_commit(repository)
  end

  test "caches the public identity gate and default branch head", %{repository: repository} do
    use_instrumented_client()

    assert {:ok, @default_commit_sha} = RepositoryCode.resolve_default_commit(repository)
    assert {:ok, @default_commit_sha} = RepositoryCode.resolve_default_commit(repository)

    assert InstrumentedGitHubClient.count(:repository) == 2
    assert InstrumentedGitHubClient.count(:head) == 1

    assert {:ok, %{github_id: github_id}} =
             Cache.get({:github_identity, repository.github_id})

    assert github_id == repository.github_id

    assert {:ok, %{sha: @default_commit_sha}} =
             Cache.get({:github_head, repository.github_id, "main"})
  end

  test "coalesces concurrent commit, tree, and blob cache misses", %{repository: repository} do
    use_instrumented_client()
    InstrumentedGitHubClient.configure(notify: self(), block_once: [:commit, :tree, :blob])

    tasks =
      concurrent_calls(8, fn -> RepositoryCode.browse(repository, @commit_sha, "README.md") end)

    assert_receive {:upstream_blocked, :commit, commit_leader}
    assert_waiter_count({:github_commit, repository.github_id, @commit_sha}, 7)
    send(commit_leader, {:release_upstream, :commit})

    root_tree_sha = String.duplicate("1", 40)
    assert_receive {:upstream_blocked, :tree, tree_leader}
    assert_waiter_count({:github_tree, repository.github_id, root_tree_sha, false}, 7)
    send(tree_leader, {:release_upstream, :tree})

    readme_blob_sha = String.duplicate("3", 40)
    assert_receive {:upstream_blocked, :blob, blob_leader}
    assert_waiter_count({:github_blob, repository.github_id, readme_blob_sha}, 7)
    send(blob_leader, {:release_upstream, :blob})

    assert Enum.all?(Task.await_many(tasks, 5_000), &match?({:ok, %File{}}, &1))
    assert InstrumentedGitHubClient.count(:commit) == 1
    assert InstrumentedGitHubClient.count(:tree) == 1
    assert InstrumentedGitHubClient.count(:blob) == 1
  end

  test "coalesces concurrent default branch head misses", %{repository: repository} do
    use_instrumented_client()
    InstrumentedGitHubClient.configure(notify: self(), block_once: [:head])

    tasks = concurrent_calls(8, fn -> RepositoryCode.resolve_default_commit(repository) end)

    assert_receive {:upstream_blocked, :head, head_leader}
    assert_waiter_count({:github_head, repository.github_id, "main"}, 7)
    send(head_leader, {:release_upstream, :head})

    assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == {:ok, @default_commit_sha}))
    assert InstrumentedGitHubClient.count(:repository) == 2
    assert InstrumentedGitHubClient.count(:head) == 1

    assert {:ok, @default_commit_sha} = RepositoryCode.resolve_default_commit(repository)
    assert InstrumentedGitHubClient.count(:repository) == 2
    assert InstrumentedGitHubClient.count(:head) == 1
  end

  test "admits verified immutable objects to the bounded cache", %{repository: repository} do
    assert {:ok, %File{}} = RepositoryCode.browse(repository, @commit_sha, "README.md")

    assert {:ok, %{sha: @commit_sha}} =
             Cache.get({:github_commit, repository.github_id, @commit_sha})

    assert {:ok, %{sha: blob_sha}} =
             Cache.get({:github_blob, repository.github_id, String.duplicate("3", 40)})

    assert blob_sha == String.duplicate("3", 40)
  end

  test "evicts cached objects and denies them after the repository becomes private", %{
    repository: repository
  } do
    use_instrumented_client()

    assert {:ok, @default_commit_sha} = RepositoryCode.resolve_default_commit(repository)
    assert {:ok, %File{}} = RepositoryCode.browse(repository, @commit_sha, "README.md")

    InstrumentedGitHubClient.configure(visibility: :private)

    assert {:error, :identity_changed} =
             RepositoryCode.browse(repository, @commit_sha, "README.md")

    assert :miss = Cache.get({:github_commit, repository.github_id, @commit_sha})

    assert :miss =
             Cache.get({:github_commit, repository.github_id, @default_commit_sha})

    assert :miss =
             Cache.get({:github_blob, repository.github_id, String.duplicate("3", 40)})

    assert :miss = Cache.get({:github_identity, repository.github_id})
    assert :miss = Cache.get({:github_head, repository.github_id, "main"})
  end

  test "lists branches with the default branch first", %{repository: repository} do
    assert {:ok, branches} = RepositoryCode.list_branches(repository)
    assert hd(branches) == "main"
    assert "develop" in branches
  end

  test "resolves a non-default branch tip to a commit SHA", %{repository: repository} do
    assert {:ok, sha} = RepositoryCode.resolve_branch_commit(repository, "develop")
    assert sha == String.duplicate("8", 40)
  end

  test "adopts the new canonical identity after a rename on the host" do
    repository =
      Repo.insert!(%Tarakan.Repositories.Repository{
        host: "github.com",
        owner: "legacy",
        name: "widget",
        canonical_url: "https://github.com/legacy/widget",
        github_id: 77_777,
        default_branch: "main",
        last_synced_at: DateTime.utc_now()
      })

    assert {:ok, %File{}} = RepositoryCode.browse(repository, @commit_sha, "README.md")

    reloaded = Repo.get!(Tarakan.Repositories.Repository, repository.id)
    assert reloaded.owner == "acme"
    assert reloaded.name == "widget"
    assert reloaded.canonical_url == "https://github.com/acme/widget"
  end

  test "revalidates an expired identity gate with a conditional request", %{
    repository: repository
  } do
    previous = Application.get_env(:tarakan, Tarakan.RepositoryCode, [])

    Application.put_env(
      :tarakan,
      Tarakan.RepositoryCode,
      Keyword.put(previous, :identity_cache_ttl_ms, 1)
    )

    on_exit(fn -> Application.put_env(:tarakan, Tarakan.RepositoryCode, previous) end)

    assert {:ok, %File{}} = RepositoryCode.browse(repository, @commit_sha, "README.md")

    assert {:ok, %{etag: etag}} = Cache.get({:github_identity_stale, repository.github_id})
    assert etag == Tarakan.GitHubStub.codex_etag()

    # Every identity check is now a conditional request answered with 304
    # (the stub only returns :not_modified when it receives the ETag).
    Process.sleep(5)
    assert {:ok, %File{}} = RepositoryCode.browse(repository, @commit_sha, "README.md")
  end

  test "does not cache an object when the post-fetch public identity check fails" do
    Process.put(:github_flip_identity_count, 0)

    repository =
      Repo.insert!(%Tarakan.Repositories.Repository{
        host: "github.com",
        owner: "flip",
        name: "repository",
        canonical_url: "https://github.com/flip/repository",
        github_id: 88_888,
        default_branch: "main",
        last_synced_at: DateTime.utc_now()
      })

    assert {:error, :identity_changed} = RepositoryCode.browse(repository, @commit_sha, "")
    assert :miss = Cache.get({:github_commit, repository.github_id, @commit_sha})
  end

  test "the final identity gate evicts objects if visibility changes during traversal" do
    Process.put(:github_late_flip_identity_count, 0)

    repository =
      Repo.insert!(%Tarakan.Repositories.Repository{
        host: "github.com",
        owner: "lateflip",
        name: "repository",
        canonical_url: "https://github.com/lateflip/repository",
        github_id: 99_999,
        default_branch: "main",
        last_synced_at: DateTime.utc_now()
      })

    assert {:error, :identity_changed} = RepositoryCode.browse(repository, @commit_sha, "")
    assert :miss = Cache.get({:github_commit, repository.github_id, @commit_sha})

    assert :miss =
             Cache.get({:github_tree, repository.github_id, String.duplicate("1", 40), false})
  end

  test "cache enforces its global entry bound" do
    for index <- 1..1_001 do
      assert :ok = Cache.put({:bounded_cache_test, index}, index, 60_000)
    end

    assert :miss = Cache.get({:bounded_cache_test, 1})
    assert {:ok, 1_001} = Cache.get({:bounded_cache_test, 1_001})
  end

  test "an exhausted repository limit does not consume the global limit", %{
    repository: repository
  } do
    previous = Application.fetch_env!(:tarakan, RepositoryCode)

    Application.put_env(:tarakan, RepositoryCode,
      global_upstream_limit: 100_000,
      repository_upstream_limit: 1,
      upstream_window_seconds: 60
    )

    on_exit(fn -> Application.put_env(:tarakan, RepositoryCode, previous) end)

    before_count = global_upstream_count()
    assert {:error, :rate_limited} = RepositoryCode.resolve_default_commit(repository)
    assert global_upstream_count() == before_count + 1
  end

  defp use_instrumented_client do
    start_supervised!(InstrumentedGitHubClient)
    previous = Application.fetch_env!(:tarakan, :github_client)
    Application.put_env(:tarakan, :github_client, InstrumentedGitHubClient)
    on_exit(fn -> Application.put_env(:tarakan, :github_client, previous) end)
  end

  defp concurrent_calls(count, callback) do
    task_supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      for _index <- 1..count do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {:task_ready, self()})

          receive do
            :start -> callback.()
          end
        end)
      end

    Enum.each(tasks, fn task ->
      assert_receive {:task_ready, pid}
      assert pid == task.pid
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
    end)

    Enum.each(tasks, &send(&1.pid, :start))
    tasks
  end

  defp assert_waiter_count(key, expected), do: assert_waiter_count(key, expected, 1_000)

  defp assert_waiter_count(_key, _expected, 0), do: flunk("cache waiters did not coalesce")

  defp assert_waiter_count(key, expected, attempts) do
    waiter_count =
      Cache
      |> :sys.get_state()
      |> Map.fetch!(:inflight)
      |> Map.get(key, %{waiters: []})
      |> Map.fetch!(:waiters)
      |> length()

    if waiter_count == expected do
      :ok
    else
      receive do
      after
        1 -> assert_waiter_count(key, expected, attempts - 1)
      end
    end
  end

  defp global_upstream_count do
    :tarakan_rate_limits
    |> :ets.tab2list()
    |> Enum.reduce(0, fn
      {{{:repository_code_upstream_global, limiter_node}, _bucket, 60}, count, _expires_at}, acc
      when limiter_node == node() ->
        acc + count

      _entry, acc ->
        acc
    end)
  end
end
