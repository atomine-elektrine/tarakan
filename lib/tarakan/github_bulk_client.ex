defmodule Tarakan.GitHubBulkClient do
  @moduledoc """
  Bulk repository metadata lookup by immutable GraphQL node id.

  One `nodes(ids: [...])` query covers up to 100 repositories for ~1 point of
  GitHub's 5,000-point/hour GraphQL budget, which is what makes fleet-wide
  rename/privatization sweeps tractable at millions of repositories.
  """

  @max_ids 100

  def max_ids, do: @max_ids

  @typedoc """
  One result per requested node id, in request order. `nil` means the node no
  longer exists or is not a repository; `:not_public` means it exists but is
  no longer publicly visible.
  """
  @type node_result :: map() | :not_public | nil

  @callback fetch_repositories_by_node_ids([String.t()]) ::
              {:ok, [node_result()]}
              | {:error, :no_token | :rate_limited | :unavailable | :invalid_response}
end
