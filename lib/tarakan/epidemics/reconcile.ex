defmodule Tarakan.Epidemics.Reconcile do
  @moduledoc """
  Nightly reconcile: enqueue RefreshPattern for source keys and drop orphan rollups.
  """

  use Oban.Worker,
    queue: :epidemics,
    max_attempts: 3,
    unique: [period: 3600, states: :incomplete]

  import Ecto.Query, warn: false

  alias Tarakan.Epidemics
  alias Tarakan.Epidemics.{Pattern, RefreshPattern}
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.{CanonicalFinding, Finding, Scan}

  require Logger

  @batch 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    last = Map.get(args, "last_pattern_key") || Map.get(args, :last_pattern_key) || ""
    phase = Map.get(args, "phase") || Map.get(args, :phase) || "source"

    case phase do
      "source" -> reconcile_source(last)
      "orphans" -> reconcile_orphans(last)
      _ -> :ok
    end
  end

  defp reconcile_source(last) do
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

    Enum.each(keys, fn key ->
      conf = Application.get_env(:tarakan, :epidemics, [])

      if Keyword.get(conf, :sync_refresh, false) do
        Epidemics.refresh_pattern!(key)
      else
        %{pattern_key: key, reason: "reconcile"}
        |> RefreshPattern.new()
        |> Oban.insert()
      end
    end)

    case keys do
      [] ->
        %{phase: "orphans", last_pattern_key: ""}
        |> __MODULE__.new()
        |> Oban.insert()

        :ok

      list ->
        %{phase: "source", last_pattern_key: List.last(list)}
        |> __MODULE__.new()
        |> Oban.insert()

        :ok
    end
  end

  defp reconcile_orphans(last) do
    keys =
      Repo.all(
        from p in Pattern,
          where: p.pattern_key > ^last,
          order_by: [asc: p.pattern_key],
          limit: @batch,
          select: p.pattern_key
      )

    Enum.each(keys, &Epidemics.refresh_pattern!/1)

    case keys do
      [] ->
        Logger.info("epidemics reconcile complete")
        :ok

      list ->
        %{phase: "orphans", last_pattern_key: List.last(list)}
        |> __MODULE__.new()
        |> Oban.insert()

        :ok
    end
  end
end
