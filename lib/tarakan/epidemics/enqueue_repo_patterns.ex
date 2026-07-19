defmodule Tarakan.Epidemics.EnqueueRepoPatterns do
  @moduledoc "Continuation job for listing fan-out when a repo has many pattern keys."

  use Oban.Worker, queue: :epidemics, max_attempts: 3

  alias Tarakan.Epidemics

  @max_inline 200

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    repository_id = Map.get(args, "repository_id") || Map.get(args, :repository_id)
    offset = Map.get(args, "offset") || Map.get(args, :offset) || 0
    reason = Map.get(args, "reason") || Map.get(args, :reason) || "listing_change"

    keys = Epidemics.pattern_keys_for_repository(repository_id)
    slice = keys |> Enum.drop(offset) |> Enum.take(@max_inline)

    Enum.each(slice, fn key ->
      conf = Application.get_env(:tarakan, :epidemics, [])

      if Keyword.get(conf, :sync_refresh, false) do
        Epidemics.refresh_pattern!(key)
      else
        %{pattern_key: key, reason: reason}
        |> Tarakan.Epidemics.RefreshPattern.new()
        |> Oban.insert()
      end
    end)

    next_offset = offset + length(slice)

    if next_offset < length(keys) do
      %{
        "repository_id" => repository_id,
        "offset" => next_offset,
        "reason" => reason
      }
      |> __MODULE__.new()
      |> Oban.insert()
    end

    :ok
  end
end
