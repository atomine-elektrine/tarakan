defmodule Tarakan.Git.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Tarakan.Git.Concurrency

  setup do
    # Drain any slots held by concurrent suite work against the global server.
    for _ <- 1..64, do: Concurrency.checkin()
    :ok
  end

  test "checkout is bounded by max_concurrent" do
    # Use a private process so we do not fight other tests over the app's
    # default max of 32 for the full suite run.
    {:ok, pid} = GenServer.start_link(Concurrency, max: 2, name: nil)

    assert :ok = GenServer.call(pid, :checkout)
    assert :ok = GenServer.call(pid, :checkout)
    assert {:error, :busy} = GenServer.call(pid, :checkout)

    GenServer.cast(pid, :checkin)
    assert :ok = GenServer.call(pid, :checkout)

    GenServer.stop(pid)
  end
end
