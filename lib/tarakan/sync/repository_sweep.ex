defmodule Tarakan.Sync.RepositorySweep do
  @moduledoc """
  Nightly fleet-wide repository sync coordinator.

  Fans the registry out into `Tarakan.Sync.RepositorySweepBatch` jobs of up to
  100 node ids each, so renames, transfers, privatizations, and metadata drift
  are caught in bulk through GitHub's GraphQL API instead of per-repository
  REST polling. Also backfills missing `node_id`s through the REST by-id
  endpoint at a bounded rate so older rows migrate into the sweep over time.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 3600, states: :incomplete]

  import Ecto.Query, warn: false

  alias Tarakan.GitHub
  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.Sync.RepositorySweepBatch

  require Logger

  @page_size 1_000
  @default_backfill_limit 200

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    backfilled = backfill_node_ids()
    swept = enqueue_batches(0, 0)

    Logger.info(
      "repository sweep enqueued #{swept} repositories, backfilled #{backfilled} node ids"
    )

    :ok
  end

  defp enqueue_batches(last_id, count) do
    ids =
      Repo.all(
        from repository in Repository,
          where: repository.id > ^last_id and not is_nil(repository.node_id),
          order_by: [asc: repository.id],
          limit: @page_size,
          select: repository.id
      )

    case ids do
      [] ->
        count

      ids ->
        ids
        |> Enum.chunk_every(Tarakan.GitHubBulkClient.max_ids())
        |> Enum.map(&RepositorySweepBatch.new(%{repository_ids: &1}))
        |> Oban.insert_all()

        enqueue_batches(List.last(ids), count + length(ids))
    end
  end

  # Bounded REST spend: rows registered before node_id existed migrate into
  # the GraphQL sweep a slice per night.
  defp backfill_node_ids do
    rows =
      Repo.all(
        from repository in Repository,
          where:
            is_nil(repository.node_id) and not is_nil(repository.github_id) and
              repository.host == "github.com",
          order_by: [asc: repository.id],
          limit: ^backfill_limit()
      )

    Enum.count(rows, fn repository ->
      case GitHub.fetch_public_repository_by_id(repository.github_id) do
        {:ok, %{github_id: github_id} = metadata} when github_id == repository.github_id ->
          match?({:ok, _updated}, Repositories.adopt_canonical_identity(repository, metadata))

        _other ->
          false
      end
    end)
  end

  defp backfill_limit do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:backfill_limit, @default_backfill_limit)
  end
end
