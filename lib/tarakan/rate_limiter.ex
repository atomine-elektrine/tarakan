defmodule Tarakan.RateLimiter do
  @moduledoc """
  Small fixed-window limiter used as a first launch boundary.

  Keys intentionally combine actor, token, IP, repository, and action at call
  sites. **This implementation is node-local (ETS).** Multi-node production
  must replace it with a shared backend (Redis, Postgres, etc.) while
  preserving `check/3`, or rate limits can be multiplied by the node count.
  """

  use GenServer

  @table :tarakan_rate_limits
  @cleanup_interval :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(key, limit, window_seconds)
      when is_integer(limit) and limit > 0 and is_integer(window_seconds) and window_seconds > 0 do
    bucket = div(System.system_time(:second), window_seconds)
    record_key = {key, bucket, window_seconds}
    expires_at = (bucket + 1) * window_seconds

    count =
      :ets.update_counter(
        @table,
        record_key,
        {2, 1},
        {record_key, 0, expires_at}
      )

    if count <= limit do
      :ok
    else
      {:error, :rate_limited, window_seconds - rem(System.system_time(:second), window_seconds)}
    end
  rescue
    ArgumentError -> {:error, :rate_limiter_unavailable, 1}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)

    for {record_key, _count, expires_at} <- :ets.tab2list(@table), expires_at <= now do
      :ets.delete(@table, record_key)
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
