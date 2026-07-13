defmodule Tarakan.RepositoryCode.InstrumentedGitHubClient do
  @moduledoc false

  @behaviour Tarakan.GitHubClient

  alias Tarakan.GitHubStub

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          calls: %{},
          notify: nil,
          block_once: MapSet.new(),
          visibility: :public
        }
      end,
      name: __MODULE__
    )
  end

  def configure(opts) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | notify: Keyword.get(opts, :notify, state.notify),
          block_once: MapSet.new(Keyword.get(opts, :block_once, [])),
          visibility: Keyword.get(opts, :visibility, state.visibility)
      }
    end)
  end

  def count(kind), do: Agent.get(__MODULE__, &Map.get(&1.calls, kind, 0))

  @impl true
  def fetch_repository(owner, name, opts \\ []) do
    record_call(:repository)

    case Agent.get(__MODULE__, & &1.visibility) do
      :public ->
        GitHubStub.fetch_repository(owner, name, opts)

      :private ->
        # A visibility change always rotates the upstream ETag, so a
        # conditional request can never mask it with a 304.
        with {:ok, metadata} <- GitHubStub.fetch_repository(owner, name) do
          {:ok, %{metadata | private: true, visibility: "private"}}
        end

      :not_found ->
        {:error, :not_found}

      {:github_id, github_id} ->
        with {:ok, metadata} <- GitHubStub.fetch_repository(owner, name) do
          {:ok, %{metadata | github_id: github_id}}
        end
    end
  end

  @impl true
  def fetch_repository_by_id(github_id) do
    record_call(:repository_by_id)

    case Agent.get(__MODULE__, & &1.visibility) do
      :public ->
        GitHubStub.fetch_repository_by_id(github_id)

      :private ->
        with {:ok, metadata} <- GitHubStub.fetch_repository_by_id(github_id) do
          {:ok, %{metadata | private: true, visibility: "private"}}
        end

      :not_found ->
        {:error, :not_found}

      {:github_id, _forced_id} ->
        GitHubStub.fetch_repository_by_id(github_id)
    end
  end

  @impl true
  def fetch_commit(owner, name, sha) do
    record_call(:commit)
    GitHubStub.fetch_commit(owner, name, sha)
  end

  @impl true
  def fetch_branch_head(owner, name, branch) do
    record_call(:head)
    GitHubStub.fetch_branch_head(owner, name, branch)
  end

  @impl true
  def fetch_tree(owner, name, tree_sha, recursive) do
    record_call(:tree)
    GitHubStub.fetch_tree(owner, name, tree_sha, recursive)
  end

  @impl true
  def fetch_text_blob(owner, name, blob_sha) do
    record_call(:blob)
    GitHubStub.fetch_text_blob(owner, name, blob_sha)
  end

  defp record_call(kind) do
    {notify, block?} =
      Agent.get_and_update(__MODULE__, fn state ->
        block? = MapSet.member?(state.block_once, kind)

        next_state = %{
          state
          | calls: Map.update(state.calls, kind, 1, &(&1 + 1)),
            block_once: MapSet.delete(state.block_once, kind)
        }

        {{state.notify, block?}, next_state}
      end)

    if block? and is_pid(notify) do
      send(notify, {:upstream_blocked, kind, self()})

      receive do
        {:release_upstream, ^kind} -> :ok
      after
        5_000 -> :ok
      end
    end
  end
end
