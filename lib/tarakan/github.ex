defmodule Tarakan.GitHub do
  @moduledoc """
  Access to canonical public repository metadata on GitHub.
  """

  def fetch_repository(owner, name, opts \\ []) do
    github_client().fetch_repository(owner, name, opts)
  end

  def fetch_repository_by_id(github_id) when is_integer(github_id) and github_id > 0 do
    github_client().fetch_repository_by_id(github_id)
  end

  @doc """
  Fetches repository metadata and rejects anything not explicitly public.

  Passing `etag:` makes the request conditional; `:not_modified` means the
  previously vetted metadata is still current.
  """
  def fetch_public_repository(owner, name, opts \\ []) do
    case fetch_repository(owner, name, opts) do
      :not_modified ->
        :not_modified

      {:ok, metadata} ->
        with :ok <- ensure_public_metadata(metadata), do: {:ok, metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Fetches repository metadata by immutable id and rejects anything not public."
  def fetch_public_repository_by_id(github_id) do
    with {:ok, metadata} <- fetch_repository_by_id(github_id),
         :ok <- ensure_public_metadata(metadata) do
      {:ok, metadata}
    end
  end

  def fetch_commit(owner, name, sha) do
    github_client().fetch_commit(owner, name, sha)
  end

  @doc "Resolves a branch head to full immutable commit and tree SHAs."
  def fetch_branch_head(owner, name, branch) do
    github_client().fetch_branch_head(owner, name, branch)
  end

  @doc "Lists branch names for a public repository (bounded first page)."
  def list_branches(owner, name) do
    github_client().list_branches(owner, name)
  end

  @doc "Fetches a Git tree by its immutable object SHA."
  def fetch_tree(owner, name, tree_sha, recursive \\ false) when is_boolean(recursive) do
    github_client().fetch_tree(owner, name, tree_sha, recursive)
  end

  @doc "Fetches and decodes a bounded text blob by its immutable object SHA."
  def fetch_text_blob(owner, name, blob_sha) do
    github_client().fetch_text_blob(owner, name, blob_sha)
  end

  @doc "Confirms a repository path still points to the registered public GitHub identity."
  def verify_public_identity(%{owner: owner, name: name, github_id: github_id}) do
    case fetch_public_repository(owner, name) do
      {:ok, %{github_id: ^github_id} = metadata} ->
        {:ok, metadata}

      {:ok, _other_identity} ->
        {:error, :identity_changed}

      {:error, reason} when reason in [:not_found, :not_public, :moved] ->
        {:error, :identity_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_public_metadata(%{
         github_id: github_id,
         owner: owner,
         name: name,
         private: false,
         visibility: "public"
       })
       when is_integer(github_id) and is_binary(owner) and is_binary(name),
       do: :ok

  defp ensure_public_metadata(_metadata), do: {:error, :not_public}

  defp github_client, do: Application.fetch_env!(:tarakan, :github_client)
end
