defmodule Tarakan.Epidemics.Backfill do
  @moduledoc "One-shot / cursor backfill of epidemic rollups from source keys."

  use Oban.Worker,
    queue: :epidemics,
    max_attempts: 3,
    unique: [period: 3600, states: :incomplete]

  import Ecto.Query, warn: false

  alias Tarakan.Epidemics
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.{CanonicalFinding, Finding, Scan}

  require Logger

  @batch 200

  @doc "Synchronous full backfill (dev/seeds/mix task)."
  def run_sync! do
    do_source("", 0)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    last = Map.get(args, "last_pattern_key") || Map.get(args, :last_pattern_key) || ""
    count = Map.get(args, "count") || Map.get(args, :count) || 0
    do_source(last, count, async: true)
  end

  defp do_source(last, count, opts \\ []) do
    async? = Keyword.get(opts, :async, false)

    keys =
      Repo.all(
        from c in CanonicalFinding,
          join: r in Repository,
          on: r.id == c.repository_id,
          join: f in Finding,
          on: f.canonical_finding_id == c.id,
          join: s in Scan,
          on: s.id == f.scan_id,
          where:
            r.listing_status == "listed" and s.visibility == "public" and
              not is_nil(c.pattern_key) and c.pattern_key != "" and c.pattern_key > ^last,
          distinct: true,
          order_by: [asc: c.pattern_key],
          limit: @batch,
          select: c.pattern_key
      )

    Enum.each(keys, &Epidemics.refresh_pattern!/1)
    new_count = count + length(keys)

    if rem(new_count, 1000) < length(keys) do
      Logger.info("epidemics backfill progress ~#{new_count} keys")
    end

    case keys do
      [] ->
        Logger.info("epidemics backfill complete (#{new_count} keys refreshed)")
        :ok

      list ->
        last_key = List.last(list)

        if async? do
          %{last_pattern_key: last_key, count: new_count}
          |> __MODULE__.new()
          |> Oban.insert()

          :ok
        else
          do_source(last_key, new_count, opts)
        end
    end
  end
end
