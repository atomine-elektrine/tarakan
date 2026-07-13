defmodule Tarakan.RepositoryCode.Cache do
  @moduledoc false

  use GenServer

  @default_max_entries 1_000
  @default_max_bytes 64 * 1_024 * 1_024
  @default_max_inflight 256
  @default_max_waiters_per_key 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def put(key, value, ttl_ms), do: GenServer.call(__MODULE__, {:put, key, value, ttl_ms})

  @doc """
  Returns a cached value or coalesces callers while one of them computes it.

  The callback runs in the elected caller, never in the cache server. Successful
  results are admitted atomically before all waiting callers are released.
  """
  def fetch(key, ttl_ms, fetch, opts \\ [])
      when is_integer(ttl_ms) and ttl_ms > 0 and is_function(fetch, 0) and is_list(opts) do
    force? = Keyword.get(opts, :force, false)

    case GenServer.call(__MODULE__, {:acquire, key, force?}, :infinity) do
      {:ok, value} ->
        {:ok, value}

      :leader ->
        result = run_fetch(fetch)
        GenServer.call(__MODULE__, {:complete, key, self(), result, ttl_ms}, :infinity)

      {:error, _reason} = error ->
        error
    end
  end

  def delete_repository(github_id),
    do: GenServer.call(__MODULE__, {:delete_repository, github_id})

  @doc "Evicts all cached objects for a Tarakan-hosted repository (e.g. after a push)."
  def delete_hosted(repository_id),
    do: GenServer.call(__MODULE__, {:delete_hosted, repository_id})

  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :private])

    {:ok,
     %{
       table: table,
       total_bytes: 0,
       sequence: 0,
       epoch: 0,
       generations: %{},
       inflight: %{},
       monitor_keys: %{},
       max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
       max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
       max_inflight: Keyword.get(opts, :max_inflight, @default_max_inflight),
       max_waiters_per_key: Keyword.get(opts, :max_waiters_per_key, @default_max_waiters_per_key)
     }}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(state.table, key) do
      [{^key, value, expires_at, _size, _sequence}] when expires_at > now ->
        {:reply, {:ok, value}, state}

      [{^key, _value, _expires_at, size, _sequence}] ->
        :ets.delete(state.table, key)
        {:reply, :miss, %{state | total_bytes: max(state.total_bytes - size, 0)}}

      [] ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put, key, value, ttl_ms}, _from, state)
      when is_integer(ttl_ms) and ttl_ms > 0 do
    state = purge_expired(state)
    state = store_value(state, key, value, ttl_ms)
    {:reply, :ok, state}
  end

  def handle_call({:acquire, key, force?}, from, state) when is_boolean(force?) do
    state = purge_expired(state)

    case Map.get(state.inflight, key) do
      nil ->
        acquire_idle_key(state, key, force?, from)

      flight ->
        join_flight(state, key, flight, from)
    end
  end

  def handle_call({:complete, key, caller, result, ttl_ms}, _from, state) do
    case Map.get(state.inflight, key) do
      %{leader: ^caller} = flight ->
        Process.demonitor(flight.monitor, [:flush])

        {result, state} = complete_flight(state, key, flight, result, ttl_ms)
        Enum.each(flight.waiters, &GenServer.reply(&1, result))

        {:reply, result,
         %{
           state
           | inflight: Map.delete(state.inflight, key),
             monitor_keys: Map.delete(state.monitor_keys, flight.monitor)
         }}

      _other ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | total_bytes: 0, epoch: state.epoch + 1, generations: %{}}}
  end

  def handle_call({:delete_repository, github_id}, _from, state) when is_integer(github_id) do
    {:reply, :ok, delete_matching(state, github_id, &repository_key?/2)}
  end

  def handle_call({:delete_hosted, repository_id}, _from, state)
      when is_integer(repository_id) do
    {:reply, :ok, delete_matching(state, {:hosted, repository_id}, &hosted_key?/2)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitor_keys, monitor) do
      {nil, monitor_keys} ->
        {:noreply, %{state | monitor_keys: monitor_keys}}

      {key, monitor_keys} ->
        case Map.pop(state.inflight, key) do
          {nil, inflight} ->
            {:noreply, %{state | inflight: inflight, monitor_keys: monitor_keys}}

          {flight, inflight} ->
            Enum.each(flight.waiters, &GenServer.reply(&1, {:error, :unavailable}))
            {:noreply, %{state | inflight: inflight, monitor_keys: monitor_keys}}
        end
    end
  end

  defp acquire_idle_key(state, key, false, from) do
    case lookup(state, key) do
      {{:ok, value}, state} -> {:reply, {:ok, value}, state}
      {:miss, state} -> start_flight(state, key, from)
    end
  end

  defp acquire_idle_key(state, key, true, from), do: start_flight(state, key, from)

  defp start_flight(state, key, {leader, _tag})
       when map_size(state.inflight) < state.max_inflight do
    monitor = Process.monitor(leader)
    github_id = repository_id(key)

    flight = %{
      leader: leader,
      monitor: monitor,
      waiters: [],
      epoch: state.epoch,
      github_id: github_id,
      generation: repository_generation(state, github_id)
    }

    {:reply, :leader,
     %{
       state
       | inflight: Map.put(state.inflight, key, flight),
         monitor_keys: Map.put(state.monitor_keys, monitor, key)
     }}
  end

  defp start_flight(state, _key, _from), do: {:reply, {:error, :unavailable}, state}

  defp join_flight(state, key, flight, from) do
    if length(flight.waiters) < state.max_waiters_per_key do
      flight = %{flight | waiters: [from | flight.waiters]}
      {:noreply, %{state | inflight: Map.put(state.inflight, key, flight)}}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  defp complete_flight(state, key, flight, result, ttl_ms) do
    cond do
      state.epoch != flight.epoch ->
        {{:error, :unavailable}, state}

      repository_invalidated?(state, flight) ->
        {{:error, :identity_changed}, state}

      match?({:ok, _value}, result) ->
        {:ok, value} = result
        {result, store_value(state, key, value, ttl_ms)}

      true ->
        {result, state}
    end
  end

  defp lookup(state, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(state.table, key) do
      [{^key, value, expires_at, _size, _sequence}] when expires_at > now ->
        {{:ok, value}, state}

      [{^key, _value, _expires_at, size, _sequence}] ->
        :ets.delete(state.table, key)
        {:miss, %{state | total_bytes: max(state.total_bytes - size, 0)}}

      [] ->
        {:miss, state}
    end
  end

  defp store_value(state, key, value, ttl_ms) do
    state = delete_existing(state, key)
    sequence = state.sequence + 1
    size = :erlang.external_size({key, value})

    if size <= state.max_bytes do
      expires_at = System.monotonic_time(:millisecond) + ttl_ms
      true = :ets.insert(state.table, {key, value, expires_at, size, sequence})

      %{state | total_bytes: state.total_bytes + size, sequence: sequence}
      |> evict_to_bounds()
    else
      %{state | sequence: sequence}
    end
  end

  defp repository_invalidated?(_state, %{github_id: nil}), do: false

  defp repository_invalidated?(state, flight) do
    repository_generation(state, flight.github_id) != flight.generation
  end

  defp repository_generation(_state, nil), do: nil
  defp repository_generation(state, github_id), do: Map.get(state.generations, github_id, 0)

  defp run_fetch(fetch) do
    case fetch.() do
      {:ok, _value} = result -> result
      {:error, _reason} = result -> result
      _other -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp purge_expired(state) do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn
        {key, _value, expires_at, size, _sequence}, acc when expires_at <= now ->
          :ets.delete(acc.table, key)
          %{acc | total_bytes: max(acc.total_bytes - size, 0)}

        _entry, acc ->
          acc
      end,
      state,
      state.table
    )
  end

  defp delete_existing(state, key) do
    case :ets.lookup(state.table, key) do
      [{^key, _value, _expires_at, size, _sequence}] ->
        :ets.delete(state.table, key)
        %{state | total_bytes: max(state.total_bytes - size, 0)}

      [] ->
        state
    end
  end

  defp evict_to_bounds(state) do
    if :ets.info(state.table, :size) > state.max_entries or
         state.total_bytes > state.max_bytes do
      case oldest_entry(state.table) do
        nil ->
          %{state | total_bytes: 0}

        {key, size} ->
          :ets.delete(state.table, key)
          evict_to_bounds(%{state | total_bytes: max(state.total_bytes - size, 0)})
      end
    else
      state
    end
  end

  defp oldest_entry(table) do
    :ets.foldl(
      fn {key, _value, _expires_at, size, sequence}, oldest ->
        case oldest do
          nil ->
            {key, size, sequence}

          {_old_key, _old_size, old_sequence} when sequence < old_sequence ->
            {key, size, sequence}

          _other ->
            oldest
        end
      end,
      nil,
      table
    )
    |> case do
      nil -> nil
      {key, size, _sequence} -> {key, size}
    end
  end

  defp delete_matching(state, generation_key, matcher) do
    state =
      :ets.foldl(
        fn {key, _value, _expires_at, size, _sequence}, acc ->
          if matcher.(key, generation_key) do
            :ets.delete(acc.table, key)
            %{acc | total_bytes: max(acc.total_bytes - size, 0)}
          else
            acc
          end
        end,
        state,
        state.table
      )

    generation = Map.get(state.generations, generation_key, 0) + 1

    %{state | generations: Map.put(state.generations, generation_key, generation)}
  end

  defp repository_key?({kind, github_id, _object_sha}, github_id)
       when kind in [:github_commit, :github_blob, :github_head],
       do: true

  defp repository_key?({:github_tree, github_id, _tree_sha, _recursive}, github_id), do: true
  defp repository_key?({:github_identity, github_id}, github_id), do: true
  defp repository_key?({:github_identity_stale, github_id}, github_id), do: true
  defp repository_key?(_key, _github_id), do: false

  defp hosted_key?({kind, repository_id, _object_sha}, {:hosted, repository_id})
       when kind in [:hosted_commit, :hosted_blob],
       do: true

  defp hosted_key?(
         {:hosted_tree, repository_id, _tree_sha, _recursive},
         {:hosted, repository_id}
       ),
       do: true

  defp hosted_key?({:hosted_head, repository_id}, {:hosted, repository_id}), do: true
  defp hosted_key?(_key, _generation_key), do: false

  defp repository_id({kind, github_id, _object_sha})
       when kind in [:github_commit, :github_blob, :github_head] and is_integer(github_id),
       do: github_id

  defp repository_id({:github_tree, github_id, _tree_sha, _recursive})
       when is_integer(github_id),
       do: github_id

  defp repository_id({:github_identity, github_id}) when is_integer(github_id), do: github_id

  defp repository_id({:github_identity_stale, github_id}) when is_integer(github_id),
    do: github_id

  # Hosted keys invalidate under a tagged generation id so a hosted
  # repository's row id can never collide with a GitHub numeric id.
  defp repository_id({kind, repository_id, _object_sha})
       when kind in [:hosted_commit, :hosted_blob] and is_integer(repository_id),
       do: {:hosted, repository_id}

  defp repository_id({:hosted_tree, repository_id, _tree_sha, _recursive})
       when is_integer(repository_id),
       do: {:hosted, repository_id}

  defp repository_id({:hosted_head, repository_id}) when is_integer(repository_id),
    do: {:hosted, repository_id}

  defp repository_id(_key), do: nil
end
