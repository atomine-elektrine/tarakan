defmodule Tarakan.GitHubClient do
  @moduledoc false

  @type error_reason ::
          :invalid_reference
          | :not_found
          | :not_public
          | :moved
          | :rate_limited
          | :unavailable
          | :invalid_response
          | :tree_too_large
          | :blob_too_large
          | :binary_blob

  @doc """
  Fetches repository metadata by owner/name.

  Accepts `etag:` for a conditional request; a `304 Not Modified` upstream
  response returns `:not_modified` and does not count against GitHub's rate
  limit. A repository that was renamed or transferred returns `{:error, :moved}`.
  """
  @callback fetch_repository(String.t(), String.t(), keyword()) ::
              {:ok, map()} | :not_modified | {:error, error_reason()}

  @doc """
  Fetches repository metadata by its immutable numeric id, following renames.
  """
  @callback fetch_repository_by_id(pos_integer()) ::
              {:ok, map()} | {:error, error_reason()}

  @callback fetch_commit(String.t(), String.t(), String.t()) ::
              {:ok,
               %{
                 sha: String.t(),
                 tree_sha: String.t(),
                 committed_at: DateTime.t() | nil
               }}
              | {:error, error_reason()}

  @callback fetch_branch_head(String.t(), String.t(), String.t()) ::
              {:ok,
               %{
                 sha: String.t(),
                 tree_sha: String.t(),
                 committed_at: DateTime.t() | nil
               }}
              | {:error, error_reason()}

  @doc """
  Lists branch names for a public repository (first page, bounded).

  Returns `{:ok, names}` ordered as returned by the host. Does not include
  remote-tracking or tag refs.
  """
  @callback list_branches(String.t(), String.t()) ::
              {:ok, [String.t()]} | {:error, error_reason()}

  @callback fetch_tree(String.t(), String.t(), String.t(), boolean()) ::
              {:ok,
               %{
                 sha: String.t(),
                 truncated: boolean(),
                 entries: [
                   %{
                     path: String.t(),
                     mode: String.t(),
                     type: String.t(),
                     sha: String.t(),
                     size: non_neg_integer() | nil
                   }
                 ]
               }}
              | {:error, error_reason()}

  @callback fetch_text_blob(String.t(), String.t(), String.t()) ::
              {:ok,
               %{
                 sha: String.t(),
                 size: non_neg_integer(),
                 content: String.t()
               }}
              | {:error, error_reason()}
end
