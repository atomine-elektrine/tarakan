defmodule Tarakan.RateLimiter do
  @moduledoc """
  Fixed-window rate limiter shared across nodes via Postgres.

  Keys intentionally combine actor, token, IP, repository, and action at call
  sites. Counts are stored in `rate_limit_buckets` so multi-node deploys share
  the same budgets. ETS is retained only as a crash fallback when the database
  is temporarily unavailable.
  """

  use GenServer

  require Logger

  alias Tarakan.Repo

  @ets_table :tarakan_rate_limits
  @cleanup_interval :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(key, limit, window_seconds)
      when is_integer(limit) and limit > 0 and is_integer(window_seconds) and window_seconds > 0 do
    bucket = div(System.system_time(:second), window_seconds)
    expires_at = (bucket + 1) * window_seconds
    encoded_key = encode_key(key)

    case postgres_check(encoded_key, bucket, expires_at) do
      {:ok, count} ->
        # Mirror into ETS for local diagnostics / tests that inspect the table.
        _ = ets_set(key, bucket, window_seconds, expires_at, count)

        if count <= limit do
          :ok
        else
          {:error, :rate_limited, max(expires_at - System.system_time(:second), 1)}
        end

      {:error, _reason} ->
        ets_check(key, bucket, expires_at, limit, window_seconds)
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [
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

    for {record_key, _count, expires_at} <- :ets.tab2list(@ets_table), expires_at <= now do
      :ets.delete(@ets_table, record_key)
    end

    _ = purge_expired_postgres(now)

    schedule_cleanup()
    {:noreply, state}
  end

  defp postgres_check(encoded_key, bucket, expires_at) do
    sql = """
    INSERT INTO rate_limit_buckets AS b (key, bucket, count, expires_at)
    VALUES ($1, $2, 1, $3)
    ON CONFLICT (key, bucket)
    DO UPDATE SET count = b.count + 1
    RETURNING count
    """

    case Repo.query(sql, [encoded_key, bucket, expires_at]) do
      {:ok, %{rows: [[count]]}} when is_integer(count) ->
        {:ok, count}

      {:error, reason} ->
        Logger.warning("rate limit postgres backend unavailable: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("rate limit postgres backend crashed: #{Exception.message(error)}")
      {:error, error}
  end

  defp ets_check(key, bucket, expires_at, limit, window_seconds) do
    count = ets_bump(key, bucket, window_seconds, expires_at)

    if count <= limit do
      :ok
    else
      {:error, :rate_limited, max(expires_at - System.system_time(:second), 1)}
    end
  rescue
    ArgumentError -> {:error, :rate_limiter_unavailable, 1}
  end

  defp ets_bump(key, bucket, window_seconds, expires_at) do
    record_key = {key, bucket, window_seconds}

    :ets.update_counter(
      @ets_table,
      record_key,
      {2, 1},
      {record_key, 0, expires_at}
    )
  end

  defp ets_set(key, bucket, window_seconds, expires_at, count) do
    record_key = {key, bucket, window_seconds}
    :ets.insert(@ets_table, {record_key, count, expires_at})
  rescue
    ArgumentError -> :ok
  end

  defp purge_expired_postgres(now) do
    Repo.query("DELETE FROM rate_limit_buckets WHERE expires_at <= $1", [now])
  rescue
    _ -> :ok
  end

  defp encode_key(key) do
    key
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
