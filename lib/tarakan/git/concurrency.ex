defmodule Tarakan.Git.Concurrency do
  @moduledoc """
  Global cap on concurrent git subprocesses (smart-HTTP RPC and SSH channels).

  Mass public disclosure with agents implies many clone/push operations. Size
  and time limits already bound each request; this limiter bounds simultaneous
  `git` processes so a flood cannot exhaust FDs/CPU on a single node.
  """

  use GenServer

  @default_max 32

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reserves one concurrency slot.

  Returns `:ok` or `{:error, :busy}`. Callers must `checkin/0` after the
  subprocess finishes (including error paths).
  """
  def checkout do
    GenServer.call(__MODULE__, :checkout)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Releases a previously checked-out slot."
  def checkin do
    GenServer.cast(__MODULE__, :checkin)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc false
  def active_count do
    GenServer.call(__MODULE__, :active_count)
  catch
    :exit, {:noproc, _} -> 0
  end

  @impl true
  def init(opts) do
    max =
      opts
      |> Keyword.get(:max)
      |> Kernel.||(config(:max_concurrent, @default_max))
      |> max(1)

    {:ok, %{active: 0, max: max}}
  end

  @impl true
  def handle_call(:checkout, _from, %{active: active, max: max} = state) do
    if active < max do
      {:reply, :ok, %{state | active: active + 1}}
    else
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call(:active_count, _from, state) do
    {:reply, state.active, state}
  end

  @impl true
  def handle_cast(:checkin, %{active: active} = state) do
    {:noreply, %{state | active: max(active - 1, 0)}}
  end

  defp config(key, default) do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
