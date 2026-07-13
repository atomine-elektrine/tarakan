defmodule Tarakan.RepositoryMirror do
  @moduledoc """
  Content-addressed local mirror of hot repositories.

  Mirrors are bare git repositories fetched over the git protocol - which is
  not metered by GitHub's API rate limits - holding exactly the pinned
  commits Tarakan serves, with trees and small blobs
  (`--filter=blob:limit=524288` matches the source-preview cap). Reads never
  touch the network (`GIT_NO_LAZY_FETCH`); anything absent or abnormal
  returns `:miss` and the caller falls back to the REST API.

  Safety posture: repositories stay bare (no checkout), hooks are disabled,
  auth prompts are off, objects are fsck'd on transfer, and every git
  invocation runs under a hard wall-clock timeout (see `Tarakan.Git.Local`).
  Mirror directories are keyed by the immutable host id, so renames never
  orphan them; identity eviction deletes them.
  """

  alias Tarakan.Git.Local
  alias Tarakan.Repositories.Repository

  require Logger

  @max_blob_bytes 512 * 1_024
  @default_fetch_timeout_seconds 300
  @default_remote_url_template "https://github.com/:owner/:name.git"

  ## Configuration

  def enabled? do
    config(:enabled, false) and is_binary(config(:root, nil))
  end

  def repository_dir(github_id) when is_integer(github_id) do
    Path.join([config!(:root), "github.com", "#{github_id}.git"])
  end

  ## Mirroring (called from the Oban worker)

  @doc "Fetches one exact commit into the repository's bare mirror."
  def mirror(%Repository{github_id: github_id} = repository, commit_sha)
      when is_integer(github_id) do
    with {:ok, commit_sha} <- Local.validate_sha(commit_sha),
         :ok <- ensure_bare_repository(repository),
         :ok <- fetch_commit_objects(repository, commit_sha) do
      {:ok, :mirrored}
    end
  end

  def mirror(_repository, _commit_sha), do: {:error, :invalid_reference}

  @doc "Removes a repository's mirror entirely (identity changed / went private)."
  def delete(github_id) when is_integer(github_id) do
    if enabled?() do
      File.rm_rf(repository_dir(github_id))
    end

    :ok
  end

  def delete(_github_id), do: :ok

  ## Local reads (no network, ever)

  def has_commit?(github_id, commit_sha) when is_integer(github_id) do
    enabled?() and Local.has_commit?(repository_dir(github_id), commit_sha)
  end

  def has_commit?(_github_id, _commit_sha), do: false

  def read_commit(github_id, commit_sha) do
    if enabled?() and is_integer(github_id) do
      Local.read_commit(repository_dir(github_id), commit_sha)
    else
      :miss
    end
  end

  def read_tree(github_id, tree_sha, recursive) when is_boolean(recursive) do
    if enabled?() and is_integer(github_id) do
      Local.read_tree(repository_dir(github_id), tree_sha, recursive)
    else
      :miss
    end
  end

  def read_blob(github_id, blob_sha) do
    if enabled?() and is_integer(github_id) do
      Local.read_blob(repository_dir(github_id), blob_sha, @max_blob_bytes)
    else
      :miss
    end
  end

  ## Fetch internals

  defp ensure_bare_repository(repository) do
    dir = repository_dir(repository.github_id)

    with :ok <- File.mkdir_p(dir),
         {:ok, _} <- run_git(dir, ["init", "--bare", "--quiet", "."]),
         {:ok, _} <- set_remote(dir, remote_url(repository)) do
      :ok
    else
      _other -> {:error, :mirror_init_failed}
    end
  end

  defp set_remote(dir, url) do
    case run_git(dir, ["remote", "add", "origin", url]) do
      {:ok, _} = ok -> ok
      {:error, _already_exists} -> run_git(dir, ["remote", "set-url", "origin", url])
    end
  end

  defp fetch_commit_objects(repository, commit_sha) do
    dir = repository_dir(repository.github_id)

    args = [
      "-c",
      "fetch.fsckObjects=true",
      "-c",
      "gc.auto=0",
      "fetch",
      "--quiet",
      "--no-tags",
      "--no-write-fetch-head",
      "--depth",
      "1",
      "--filter=blob:limit=#{@max_blob_bytes}",
      "origin",
      commit_sha
    ]

    case run_git(dir, args, fetch_timeout_seconds()) do
      {:ok, _output} ->
        :ok

      {:error, {status, output}} ->
        Logger.warning(
          "mirror fetch failed for repository #{repository.github_id} " <>
            "(status #{inspect(status)}): #{String.slice(to_string(output), 0, 500)}"
        )

        {:error, :fetch_failed}
    end
  end

  defp remote_url(repository) do
    config(:remote_url_template, @default_remote_url_template)
    |> String.replace(":owner", repository.owner)
    |> String.replace(":name", repository.name)
  end

  defp run_git(dir, args, timeout_seconds \\ 30) do
    Local.run(dir, args, timeout_seconds: timeout_seconds, config: auth_config_pairs())
  end

  # The auth header travels through the environment so the token never
  # appears in argv.
  defp auth_config_pairs do
    case api_token() do
      nil -> []
      token -> [{"http.https://github.com/.extraHeader", "Authorization: Bearer #{token}"}]
    end
  end

  defp api_token do
    case Application.fetch_env!(:tarakan, :github)[:api_token] do
      token when is_binary(token) and token != "" -> token
      _missing -> nil
    end
  end

  defp fetch_timeout_seconds, do: config(:fetch_timeout_seconds, @default_fetch_timeout_seconds)

  defp config(key, default) do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp config!(key) do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch!(key)
  end
end
