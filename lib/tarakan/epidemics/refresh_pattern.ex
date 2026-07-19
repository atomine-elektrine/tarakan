defmodule Tarakan.Epidemics.RefreshPattern do
  @moduledoc "Full recompute of one epidemic pattern_key into rollup tables."

  use Oban.Worker,
    queue: :epidemics,
    max_attempts: 5,
    unique: [
      period: 30,
      fields: [:args, :worker],
      keys: [:pattern_key],
      states: :incomplete
    ]

  alias Tarakan.Epidemics

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pattern_key" => pattern_key}})
      when is_binary(pattern_key) and pattern_key != "" do
    Epidemics.refresh_pattern!(pattern_key)
    :ok
  end

  def perform(%Oban.Job{args: %{pattern_key: pattern_key}})
      when is_binary(pattern_key) and pattern_key != "" do
    Epidemics.refresh_pattern!(pattern_key)
    :ok
  end

  def perform(_job), do: :ok
end
