defmodule Tarakan.GitHubBulkStub do
  @moduledoc """
  Bulk-lookup stub. Tests script responses per node id with
  `put_response/2`; unscripted ids resolve to `nil` (node gone).
  """

  @behaviour Tarakan.GitHubBulkClient

  def put_response(node_id, response) do
    Process.put({__MODULE__, node_id}, response)
  end

  @impl true
  def fetch_repositories_by_node_ids(node_ids) when is_list(node_ids) do
    case Process.get({__MODULE__, :batch_error}) do
      nil -> {:ok, Enum.map(node_ids, &Process.get({__MODULE__, &1}))}
      reason -> {:error, reason}
    end
  end

  def fail_batches_with(reason), do: Process.put({__MODULE__, :batch_error}, reason)
end
