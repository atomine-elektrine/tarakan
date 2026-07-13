defmodule Tarakan.Sync.RepositorySweepTest do
  use Tarakan.DataCase, async: false
  use Oban.Testing, repo: Tarakan.Repo

  alias Tarakan.GitHubBulkStub
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryCode.Cache
  alias Tarakan.Sync.{RepositorySweep, RepositorySweepBatch}

  import Tarakan.ScansFixtures

  @codex_node_id "R_kgDOcodex000"

  setup do
    Cache.clear()
    %{repository: github_repository_fixture()}
  end

  defp codex_metadata(overrides) do
    Map.merge(
      %{
        github_id: 95_959_834,
        node_id: @codex_node_id,
        host: "github.com",
        owner: "openai",
        name: "codex",
        canonical_url: "https://github.com/openai/codex",
        default_branch: "main",
        description: "Lightweight coding agent that runs in your terminal",
        primary_language: "Rust",
        stars_count: 42_000,
        forks_count: 4_200,
        archived: false,
        private: false,
        visibility: "public",
        last_synced_at: DateTime.utc_now()
      },
      overrides
    )
  end

  test "registration stores the immutable node id", %{repository: repository} do
    assert repository.node_id == @codex_node_id
  end

  test "batch adopts a rename discovered by the sweep", %{repository: repository} do
    GitHubBulkStub.put_response(
      @codex_node_id,
      codex_metadata(%{
        owner: "OpenAI-Labs",
        canonical_url: "https://github.com/openai-labs/codex"
      })
    )

    assert :ok =
             perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})

    reloaded = Repo.get!(Repository, repository.id)
    assert reloaded.owner == "openai-labs"
    assert reloaded.name == "codex"
    assert reloaded.canonical_url == "https://github.com/openai-labs/codex"
  end

  test "batch updates drifted metadata in place", %{repository: repository} do
    GitHubBulkStub.put_response(
      @codex_node_id,
      codex_metadata(%{stars_count: 50_000, description: "Updated description"})
    )

    assert :ok = perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})

    reloaded = Repo.get!(Repository, repository.id)
    assert reloaded.stars_count == 50_000
    assert reloaded.description == "Updated description"
  end

  test "batch leaves an unchanged repository untouched", %{repository: repository} do
    GitHubBulkStub.put_response(@codex_node_id, codex_metadata(%{}))

    assert :ok = perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})

    reloaded = Repo.get!(Repository, repository.id)
    assert reloaded.updated_at == repository.updated_at
  end

  test "batch evicts cached code when the repository went private", %{repository: repository} do
    Cache.put({:github_commit, repository.github_id, String.duplicate("8", 40)}, %{}, 60_000)
    GitHubBulkStub.put_response(@codex_node_id, :not_public)

    assert :ok = perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})

    assert :miss = Cache.get({:github_commit, repository.github_id, String.duplicate("8", 40)})
  end

  test "batch evicts cached code when the node no longer resolves", %{repository: repository} do
    Cache.put({:github_blob, repository.github_id, String.duplicate("3", 40)}, %{}, 60_000)
    # No scripted response: the stub resolves unknown ids to nil.

    assert :ok = perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})

    assert :miss = Cache.get({:github_blob, repository.github_id, String.duplicate("3", 40)})
  end

  test "batch evicts cached code when the node resolved to another repository", %{
    repository: repository
  } do
    Cache.put({:github_tree, repository.github_id, String.duplicate("1", 40), false}, %{}, 60_000)
    GitHubBulkStub.put_response(@codex_node_id, codex_metadata(%{github_id: 1}))

    assert :ok = perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})

    assert :miss =
             Cache.get({:github_tree, repository.github_id, String.duplicate("1", 40), false})
  end

  test "batch snoozes when the bulk API is rate limited", %{repository: repository} do
    GitHubBulkStub.fail_batches_with(:rate_limited)

    assert {:snooze, 900} =
             perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})
  end

  test "batch skips cleanly without a configured token", %{repository: repository} do
    GitHubBulkStub.fail_batches_with(:no_token)

    assert :ok = perform_job(RepositorySweepBatch, %{"repository_ids" => [repository.id]})
  end

  test "coordinator enqueues batches for every repository with a node id", %{
    repository: repository
  } do
    assert :ok = perform_job(RepositorySweep, %{})

    assert [job] = all_enqueued(worker: RepositorySweepBatch)
    assert job.args["repository_ids"] == [repository.id]
  end

  test "coordinator backfills node ids through the immutable REST id" do
    legacy =
      Repo.insert!(%Repository{
        host: "github.com",
        owner: "legacy",
        name: "widget",
        canonical_url: "https://github.com/legacy/widget",
        github_id: 77_777,
        default_branch: "main",
        last_synced_at: DateTime.utc_now()
      })

    assert :ok = perform_job(RepositorySweep, %{})

    reloaded = Repo.get!(Repository, legacy.id)
    assert reloaded.node_id == "R_kgDOwidget00"
    # The by-id lookup also adopted the rename that stranded this row.
    assert reloaded.owner == "acme"

    batch_ids =
      for job <- all_enqueued(worker: RepositorySweepBatch),
          id <- job.args["repository_ids"],
          do: id

    assert legacy.id in batch_ids
  end
end
