defmodule Tarakan.Epidemics.RecomputeWindows do
  @moduledoc """
  Hourly cheap recompute of window columns from epidemic_pattern_instances.
  Chains via last_pattern_key cursor.
  """

  use Oban.Worker,
    queue: :epidemics,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete]

  import Ecto.Query, warn: false

  alias Tarakan.Epidemics
  alias Tarakan.Epidemics.Pattern
  alias Tarakan.Repo

  require Logger

  @batch 200

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    last = Map.get(args, "last_pattern_key") || Map.get(args, :last_pattern_key) || ""

    keys =
      Repo.all(
        from p in Pattern,
          where: p.pattern_key > ^last,
          order_by: [asc: p.pattern_key],
          limit: @batch,
          select: p.pattern_key
      )

    Enum.each(keys, &Epidemics.recompute_windows!/1)

    case keys do
      [] ->
        Logger.info("epidemics recompute_windows complete")
        :ok

      list ->
        last_key = List.last(list)

        %{last_pattern_key: last_key}
        |> __MODULE__.new()
        |> Oban.insert()

        :ok
    end
  end
end
