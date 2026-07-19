defmodule Tarakan.RepositoryCode do
  @moduledoc """
  Read-only browsing of a registered repository at one exact commit.

  The browser never checks out or executes repository content. It starts at
  the tree SHA returned for the requested full commit SHA and follows only
  child object SHAs. GitHub-registered repositories are read from the local
  mirror with a REST API fallback; Tarakan-hosted repositories are read from
  their bare repository on disk and never touch the network.
  """

  alias Tarakan.Git.Local
  alias Tarakan.GitHub
  alias Tarakan.HostedRepositories.Storage
  alias Tarakan.Repo
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryCode.{Cache, Entry, File, Tree}
  alias Tarakan.RepositoryMirror
  alias Tarakan.RepositoryPath

  require Logger

  # Commits, trees, and blobs are content-addressed by SHA and can never
  # change; only refs (identity, branch heads) need short lifetimes.
  @immutable_ttl_ms :timer.hours(24)
  @identity_ttl_ms :timer.seconds(3)
  @identity_revalidation_ttl_ms :timer.hours(24)
  @head_ttl_ms :timer.seconds(12)
  @max_blob_bytes 512 * 1_024
  @max_blob_lines 10_000
  @full_sha ~r/\A[0-9a-fA-F]{40}\z/

  @type browse_error ::
          :invalid_commit_sha
          | :invalid_path
          | :empty_repository
          | :identity_changed
          | :commit_mismatch
          | :not_found
          | :not_a_directory
          | :tree_truncated
          | :tree_too_large
          | :blob_too_large
          | :binary_blob
          | :unsupported_entry
          | :rate_limited
          | :unavailable
          | :invalid_response

  @doc "Browses a root, directory, or bounded UTF-8 file at an exact full commit SHA."
  @spec browse(%Repository{}, String.t(), String.t() | nil, keyword()) ::
          {:ok, Tree.t() | File.t()} | {:error, browse_error()}
  def browse(repository, commit_sha, path, opts \\ [])

  def browse(%Repository{} = repository, commit_sha, path, opts) when is_list(opts) do
    with_rate_limit_opts(opts, fn ->
      with {:ok, repository} <- canonical_repository(repository),
           {:ok, commit_sha} <- normalize_commit_sha(commit_sha),
           {:ok, path} <- RepositoryPath.normalize(path),
           {:ok, repository} <- current_identity(repository),
           {:ok, commit} <- fetch_commit(repository, commit_sha),
           {:ok, result} <- browse_commit_path(repository, commit, path, false),
           :ok <- maybe_final_identity_check(repository, opts) do
        maybe_enqueue_mirror(repository, commit_sha)
        {:ok, result}
      end
    end)
  end

  def browse(_repository, _commit_sha, _path, _opts), do: {:error, :not_found}

  @doc "Lists a complete directory, optionally recursively, and rejects truncated responses."
  @spec list_tree(%Repository{}, String.t(), String.t() | nil, keyword()) ::
          {:ok, Tree.t()} | {:error, browse_error()}
  def list_tree(%Repository{} = repository, commit_sha, path \\ "", opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    if is_boolean(recursive) do
      with {:ok, repository} <- canonical_repository(repository),
           {:ok, commit_sha} <- normalize_commit_sha(commit_sha),
           {:ok, path} <- RepositoryPath.normalize(path),
           {:ok, repository} <- current_identity(repository),
           {:ok, commit} <- fetch_commit(repository, commit_sha),
           {:ok, %Tree{} = tree} <- browse_commit_path(repository, commit, path, recursive),
           {:ok, _metadata} <- verify_public_identity(repository, force: true) do
        {:ok, tree}
      else
        {:ok, %File{}} -> {:error, :not_a_directory}
        error -> error
      end
    else
      {:error, :invalid_response}
    end
  end

  @doc "Resolves the repository's current default branch to a full immutable commit SHA."
  @spec resolve_default_commit(%Repository{}, keyword()) ::
          {:ok, String.t()} | {:error, browse_error()}
  def resolve_default_commit(repository, opts \\ [])

  def resolve_default_commit(%Repository{} = repository, opts) when is_list(opts) do
    with_rate_limit_opts(opts, fn ->
      do_resolve_default_commit(repository)
    end)
  end

  def resolve_default_commit(_repository, _opts), do: {:error, :not_found}

  defp do_resolve_default_commit(%Repository{} = repository) do
    with {:ok, repository} <- canonical_repository(repository) do
      if Repository.hosted?(repository) do
        resolve_hosted_head(repository)
      else
        with {:ok, metadata} <- verify_public_identity(repository),
             repository = rebind_identity(repository, metadata),
             branch when is_binary(branch) and branch != "" <- Map.get(metadata, :default_branch) do
          resolve_branch_commit(repository, branch)
        else
          nil -> {:error, :invalid_response}
          "" -> {:error, :invalid_response}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :invalid_response}
        end
      end
    end
  end

  @doc """
  Resolves any branch tip to a full immutable commit SHA.

  Jobs and the code browser stay commit-pinned; branches are only a way to
  pick the tip at request time.
  """
  @spec resolve_branch_commit(%Repository{}, String.t()) ::
          {:ok, String.t()} | {:error, browse_error() | :invalid_reference}
  def resolve_branch_commit(%Repository{} = repository, branch) when is_binary(branch) do
    with {:ok, repository} <- canonical_repository(repository),
         {:ok, branch} <- normalize_branch_name(branch) do
      if Repository.hosted?(repository) do
        resolve_hosted_branch(repository, branch)
      else
        resolve_github_branch(repository, branch)
      end
    end
  end

  def resolve_branch_commit(_repository, _branch), do: {:error, :invalid_reference}

  @doc """
  Lists branch names for branch pickers. Default branch is first when known.

  Hosted repos read local refs; GitHub-backed repos use the public API (first
  page, up to 100 names).
  """
  @spec list_branches(%Repository{}) ::
          {:ok, [String.t()]} | {:error, browse_error() | :invalid_reference}
  def list_branches(%Repository{} = repository) do
    with {:ok, repository} <- canonical_repository(repository) do
      if Repository.hosted?(repository) do
        list_hosted_branches(repository)
      else
        list_github_branches(repository)
      end
    end
  end

  def list_branches(_repository), do: {:error, :not_found}

  # A hosted repository's HEAD is authoritative locally; an unborn HEAD is
  # the normal state of a repository nothing has been pushed to yet.
  defp resolve_hosted_head(repository) do
    key = {:hosted_head, repository.id}

    Cache.fetch(key, cache_ttl(:head_cache_ttl_ms, @head_ttl_ms), fn ->
      case Local.head_commit(Storage.dir(repository)) do
        {:ok, %{sha: sha}} -> {:ok, sha}
        :empty -> {:error, :empty_repository}
        :miss -> {:error, :unavailable}
      end
    end)
  end

  defp resolve_hosted_branch(repository, branch) do
    key = {:hosted_branch_head, repository.id, branch}

    Cache.fetch(key, cache_ttl(:head_cache_ttl_ms, @head_ttl_ms), fn ->
      case Local.branch_head(Storage.dir(repository), branch) do
        {:ok, sha} -> {:ok, sha}
        :miss -> {:error, :not_found}
      end
    end)
  end

  defp resolve_github_branch(repository, branch) do
    # Prefer unlimited git protocol; REST only if mirror/ls-remote cannot answer.
    case resolve_github_branch_via_git(repository, branch) do
      {:ok, sha} ->
        {:ok, sha}

      {:error, _reason} ->
        with {:ok, metadata} <- verify_public_identity(repository),
             repository = rebind_identity(repository, metadata),
             {:ok, commit} <- fetch_branch_head(repository, branch),
             :ok <- cache_commit(repository, commit) do
          {:ok, commit.sha}
        end
    end
  end

  defp resolve_github_branch_via_git(repository, branch) do
    if RepositoryMirror.enabled?() do
      with {:ok, sha} <- RepositoryMirror.ls_remote_sha(repository, branch || "HEAD"),
           :ok <- RepositoryMirror.ensure_commit(repository, sha) do
        {:ok, sha}
      end
    else
      {:error, :unavailable}
    end
  end

  defp list_hosted_branches(repository) do
    case Local.branches(Storage.dir(repository)) do
      {:ok, names} -> {:ok, order_branches(names, repository.default_branch)}
      :miss -> {:error, :unavailable}
    end
  end

  defp list_github_branches(repository) do
    key = {:github_branches, repository.github_id}

    Cache.fetch(key, cache_ttl(:head_cache_ttl_ms, @head_ttl_ms), fn ->
      with :ok <- upstream_preflight(repository),
           {:ok, metadata} <- verify_public_identity(repository),
           repository = rebind_identity(repository, metadata),
           {:ok, names} <- GitHub.list_branches(repository.owner, repository.name) do
        {:ok, order_branches(names, repository.default_branch || metadata[:default_branch])}
      end
    end)
  end

  defp order_branches(names, default_branch) do
    names = names |> Enum.uniq() |> Enum.reject(&(&1 in [nil, ""]))

    cond do
      is_binary(default_branch) and default_branch in names ->
        [default_branch | Enum.reject(names, &(&1 == default_branch))]

      true ->
        names
    end
  end

  defp normalize_branch_name(branch) when is_binary(branch) do
    branch = String.trim(branch)

    cond do
      branch == "" ->
        {:error, :invalid_reference}

      byte_size(branch) > 250 ->
        {:error, :invalid_reference}

      String.contains?(branch, ["..", "@{", "\\", "\0"]) ->
        {:error, :invalid_reference}

      true ->
        {:ok, branch}
    end
  end

  @doc "Compatibility name for resolving the repository code entry point."
  def resolve_entry_commit(%Repository{} = repository), do: resolve_default_commit(repository)
  def resolve_entry_commit(_repository), do: {:error, :not_found}

  defp browse_commit_path(repository, commit, "", recursive) do
    with {:ok, tree} <- fetch_tree(repository, commit.tree_sha, recursive) do
      build_tree(commit.sha, "", tree)
    end
  end

  defp browse_commit_path(repository, commit, path, recursive) do
    segments = String.split(path, "/")

    with {:ok, entry} <- resolve_entry(repository, commit.tree_sha, segments) do
      case entry.type do
        "tree" ->
          with {:ok, tree} <- fetch_tree(repository, entry.sha, recursive) do
            build_tree(commit.sha, path, tree)
          end

        "blob" ->
          build_file(repository, commit.sha, path, entry)

        type when type in ["symlink", "submodule"] ->
          {:error, :unsupported_entry}

        _other ->
          {:error, :invalid_response}
      end
    end
  end

  defp resolve_entry(repository, tree_sha, [segment | rest]) do
    with {:ok, tree} <- fetch_tree(repository, tree_sha, false),
         :ok <- require_complete_tree(tree),
         %{} = entry <- Enum.find(tree.entries, &(&1.path == segment)) do
      case rest do
        [] ->
          {:ok, entry}

        _remaining when entry.type == "tree" ->
          resolve_entry(repository, entry.sha, rest)

        _remaining ->
          {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp resolve_entry(_repository, _tree_sha, []), do: {:error, :not_found}

  defp build_tree(commit_sha, base_path, tree) do
    with :ok <- require_complete_tree(tree) do
      entries = Enum.map(tree.entries, &build_entry(&1, base_path))

      if Enum.all?(entries, &match?(%Entry{}, &1)) do
        entries =
          Enum.sort_by(entries, fn entry ->
            {entry_sort_order(entry.type), String.downcase(entry.path), entry.path}
          end)

        {:ok,
         %Tree{
           commit_sha: commit_sha,
           path: base_path,
           tree_sha: tree.sha,
           entries: entries,
           truncated: false
         }}
      else
        {:error, :invalid_response}
      end
    end
  end

  defp build_entry(entry, base_path) do
    with {:ok, path} <- join_path(base_path, entry.path),
         {:ok, type} <- entry_type(entry.type) do
      %Entry{
        name: entry.path |> String.split("/") |> List.last(),
        path: path,
        type: type,
        mode: entry.mode,
        sha: entry.sha,
        size: entry.size
      }
    else
      _error -> :invalid_entry
    end
  end

  defp build_file(repository, commit_sha, path, entry) do
    with :ok <- validate_entry_blob_size(entry.size),
         {:ok, blob} <- fetch_blob(repository, entry.sha),
         :ok <- ensure_blob_matches_entry(blob, entry),
         :ok <- validate_text(blob.content) do
      {:ok,
       %File{
         commit_sha: commit_sha,
         path: path,
         blob_sha: blob.sha,
         size: blob.size,
         content: blob.content
       }}
    end
  end

  defp fetch_commit(repository, commit_sha) do
    key = commit_cache_key(repository, commit_sha)

    cached_fetch(repository, key, fn ->
      with {:ok, commit} <- source_fetch_commit(repository, commit_sha),
           {:ok, commit} <- validate_commit(commit),
           true <- commit.sha == commit_sha do
        {:ok, commit}
      else
        false -> {:error, :commit_mismatch}
        error -> error
      end
    end)
  end

  defp fetch_tree(repository, tree_sha, recursive) do
    key = tree_cache_key(repository, tree_sha, recursive)

    cached_fetch(repository, key, fn ->
      with {:ok, tree} <- source_fetch_tree(repository, tree_sha, recursive),
           {:ok, tree} <- validate_tree(tree),
           true <- tree.sha == tree_sha do
        {:ok, tree}
      else
        false -> {:error, :invalid_response}
        error -> error
      end
    end)
  end

  defp fetch_blob(repository, blob_sha) do
    key = blob_cache_key(repository, blob_sha)

    cached_fetch(repository, key, fn ->
      with {:ok, blob} <- source_fetch_blob(repository, blob_sha),
           {:ok, blob} <- validate_blob(blob),
           true <- blob.sha == blob_sha do
        {:ok, blob}
      else
        false -> {:error, :invalid_response}
        error -> error
      end
    end)
  end

  defp fetch_branch_head(repository, branch) do
    key = {:github_head, repository.github_id, branch}

    Cache.fetch(key, cache_ttl(:head_cache_ttl_ms, @head_ttl_ms), fn ->
      with :ok <- upstream_preflight(repository),
           {:ok, commit} <-
             GitHub.fetch_branch_head(repository.owner, repository.name, branch),
           {:ok, commit} <- validate_commit(commit),
           {:ok, _metadata} <- verify_public_identity(repository, force: true) do
        {:ok, commit}
      else
        {:error, reason} -> {:error, reason}
        _other -> {:error, :invalid_response}
      end
    end)
  end

  # GitHub path: prefer the local git mirror (unlimited vs REST). On miss we
  # `git fetch` the commit into the mirror, then re-read. REST is only a
  # last-resort fallback when mirrors are disabled or git fails.
  defp source_fetch_commit(repository, commit_sha) do
    if Repository.hosted?(repository) do
      case Local.read_commit(Storage.dir(repository), commit_sha) do
        {:ok, commit} -> {:ok, commit}
        :miss -> {:error, :not_found}
      end
    else
      github_object(
        repository,
        commit_sha,
        fn ->
          RepositoryMirror.read_commit(repository.github_id, commit_sha)
        end,
        fn ->
          GitHub.fetch_commit(repository.owner, repository.name, commit_sha)
        end
      )
    end
  end

  defp source_fetch_tree(repository, tree_sha, recursive) do
    if Repository.hosted?(repository) do
      case Local.read_tree(Storage.dir(repository), tree_sha, recursive) do
        {:ok, tree} -> {:ok, tree}
        :miss -> {:error, :not_found}
      end
    else
      read = fn -> RepositoryMirror.read_tree(repository.github_id, tree_sha, recursive) end

      case read.() do
        {:ok, tree} ->
          {:ok, tree}

        :miss ->
          if RepositoryMirror.enabled?() do
            _ = ensure_default_mirrored(repository)

            case read.() do
              {:ok, tree} ->
                {:ok, tree}

              :miss ->
                rest_fallback(repository, fn ->
                  GitHub.fetch_tree(repository.owner, repository.name, tree_sha, recursive)
                end)
            end
          else
            rest_fallback(repository, fn ->
              GitHub.fetch_tree(repository.owner, repository.name, tree_sha, recursive)
            end)
          end
      end
    end
  end

  defp source_fetch_blob(repository, blob_sha) do
    if Repository.hosted?(repository) do
      case Local.read_blob(Storage.dir(repository), blob_sha) do
        {:ok, blob} -> {:ok, blob}
        :miss -> {:error, :not_found}
      end
    else
      read = fn -> RepositoryMirror.read_blob(repository.github_id, blob_sha) end

      case read.() do
        {:ok, blob} ->
          {:ok, blob}

        :miss ->
          if RepositoryMirror.enabled?() do
            _ = ensure_default_mirrored(repository)

            case read.() do
              {:ok, blob} ->
                {:ok, blob}

              :miss ->
                rest_fallback(repository, fn ->
                  GitHub.fetch_text_blob(repository.owner, repository.name, blob_sha)
                end)
            end
          else
            rest_fallback(repository, fn ->
              GitHub.fetch_text_blob(repository.owner, repository.name, blob_sha)
            end)
          end
      end
    end
  end

  defp github_object(repository, commit_sha, read_fun, rest_fun) do
    case read_fun.() do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case RepositoryMirror.ensure_commit(repository, commit_sha) do
          :ok ->
            case read_fun.() do
              {:ok, value} -> {:ok, value}
              :miss -> rest_fallback(repository, rest_fun)
            end

          {:error, _reason} ->
            rest_fallback(repository, rest_fun)
        end
    end
  end

  defp ensure_default_mirrored(%Repository{} = repository) do
    if RepositoryMirror.enabled?() do
      with {:ok, sha} <- RepositoryMirror.ls_remote_sha(repository, "HEAD") do
        RepositoryMirror.ensure_commit(repository, sha)
      end
    else
      {:error, :disabled}
    end
  end

  defp rest_fallback(repository, fun) when is_function(fun, 0) do
    if rest_fallback_enabled?() do
      with :ok <- upstream_preflight(repository) do
        case fun.() do
          {:error, :rate_limited} ->
            # Prefer a neutral unavailable over "code browser is busy".
            {:error, :unavailable}

          result ->
            case verify_public_identity(repository, force: true) do
              {:ok, _} -> result
              {:error, :rate_limited} -> result
              {:error, reason} -> {:error, reason}
            end
        end
      end
    else
      {:error, :unavailable}
    end
  end

  defp rest_fallback_enabled? do
    :tarakan
    |> Application.get_env(Tarakan.RepositoryMirror, [])
    |> Keyword.get(:rest_fallback, true)
  end

  # Operators skipping rate limits also skip the mandatory REST identity re-check
  # so mass code browsing stays on the git mirror path only.
  defp maybe_final_identity_check(repository, opts) do
    if Keyword.get(opts, :skip_rate_limit, false) or Process.get(:tarakan_skip_code_rate_limit) do
      :ok
    else
      case verify_public_identity(repository, force: true) do
        {:ok, _} -> :ok
        # Never surface GitHub REST quota as "code browser is busy".
        {:error, :rate_limited} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Hot-tier admission: keep background mirror warm. Never break the request.
  defp maybe_enqueue_mirror(repository, commit_sha) do
    if not Repository.hosted?(repository) and RepositoryMirror.enabled?() and
         not RepositoryMirror.has_commit?(repository.github_id, commit_sha) do
      %{repository_id: repository.id, commit_sha: commit_sha}
      |> Tarakan.Sync.MirrorRepository.new()
      |> Oban.insert()
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cached_fetch(_repository, key, fetch) do
    # Hosted + mirrored git reads are local. REST identity is checked only in
    # rest_fallback/2 when the API is actually used.
    Cache.fetch(key, cache_ttl(:immutable_cache_ttl_ms, @immutable_ttl_ms), fetch)
  end

  defp cache_commit(repository, commit) do
    key = commit_cache_key(repository, commit.sha)

    case Cache.get(key) do
      {:ok, _cached_commit} -> :ok
      :miss -> Cache.put(key, commit, cache_ttl(:immutable_cache_ttl_ms, @immutable_ttl_ms))
    end
  end

  defp canonical_repository(%Repository{id: id}) when is_integer(id) do
    case Repo.get(Repository, id) do
      %Repository{host: "github.com", github_id: github_id} = repository
      when is_integer(github_id) and github_id > 0 ->
        {:ok, repository}

      %Repository{} = repository ->
        if Repository.hosted?(repository) do
          {:ok, repository}
        else
          {:error, :invalid_response}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp canonical_repository(_repository), do: {:error, :not_found}

  defp verify_public_identity(repository, opts \\ []) do
    if Repository.hosted?(repository) do
      # A hosted repository *is* its local record; there is no upstream
      # identity that could drift.
      {:ok, %{}}
    else
      force? = Keyword.get(opts, :force, false)
      key = {:github_identity, repository.github_id}

      Cache.fetch(
        key,
        cache_ttl(:identity_cache_ttl_ms, @identity_ttl_ms),
        fn -> fetch_public_identity(repository) end,
        force: force?
      )
    end
  end

  defp fetch_public_identity(repository) do
    with :ok <- upstream_preflight(repository) do
      stale = stale_identity(repository)

      case GitHub.fetch_public_repository(repository.owner, repository.name,
             etag: stale && stale.etag
           ) do
        :not_modified ->
          revalidated_identity(repository, stale)

        {:ok, %{github_id: github_id} = metadata} when github_id == repository.github_id ->
          remember_identity(repository, metadata)
          {:ok, metadata}

        {:ok, _other_identity} ->
          resolve_moved_identity(repository)

        {:error, reason} when reason in [:not_found, :not_public, :moved] ->
          resolve_moved_identity(repository)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # An upstream 304 is free against GitHub's rate limit and proves the
  # previously vetted public metadata is unchanged.
  defp revalidated_identity(repository, %{metadata: %{github_id: github_id} = metadata})
       when github_id == repository.github_id,
       do: {:ok, metadata}

  defp revalidated_identity(_repository, _stale), do: {:error, :unavailable}

  defp stale_identity(repository) do
    case Cache.get({:github_identity_stale, repository.github_id}) do
      {:ok, %{etag: etag, metadata: metadata}} when is_binary(etag) and etag != "" ->
        %{etag: etag, metadata: metadata}

      _other ->
        nil
    end
  end

  defp remember_identity(repository, %{etag: etag} = metadata)
       when is_binary(etag) and etag != "" do
    Cache.put(
      {:github_identity_stale, repository.github_id},
      %{etag: etag, metadata: metadata},
      cache_ttl(:identity_revalidation_ttl_ms, @identity_revalidation_ttl_ms)
    )
  end

  defp remember_identity(_repository, _metadata), do: :ok

  # The registered path no longer serves this repository. The numeric id is
  # immutable, so resolve it directly: a public repository that merely moved
  # keeps working under its new owner/name; anything else fails closed.
  defp resolve_moved_identity(repository) do
    case GitHub.fetch_public_repository_by_id(repository.github_id) do
      {:ok, %{github_id: github_id} = metadata} when github_id == repository.github_id ->
        case Repositories.adopt_canonical_identity(repository, metadata) do
          {:ok, _updated_repository} ->
            Logger.info(
              "repository #{repository.github_id} moved: " <>
                "#{repository.owner}/#{repository.name} -> #{metadata.owner}/#{metadata.name}"
            )

            remember_identity(repository, metadata)
            {:ok, metadata}

          {:error, _reason} ->
            evict_changed_identity(repository)
        end

      _other ->
        evict_changed_identity(repository)
    end
  end

  defp current_identity(repository) do
    case verify_public_identity(repository) do
      {:ok, metadata} ->
        {:ok, rebind_identity(repository, metadata)}

      # Code is served from git mirrors; do not block browsing when GitHub's
      # REST identity budget is exhausted.
      {:error, :rate_limited} ->
        {:ok, repository}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Continue the request under the host's current canonical owner/name so a
  # just-renamed repository doesn't 301 on every object fetch.
  defp rebind_identity(repository, %{owner: owner, name: name})
       when is_binary(owner) and is_binary(name) do
    %{repository | owner: owner, name: name}
  end

  defp rebind_identity(repository, _metadata), do: repository

  defp evict_changed_identity(repository) do
    :ok = Cache.delete_repository(repository.github_id)
    RepositoryMirror.delete(repository.github_id)
    {:error, :identity_changed}
  end

  # Git-first code path: do not gate object reads on Tarakan-side upstream
  # budgets. GitHub REST 429 is handled by soft-failing identity and falling
  # through to git mirrors; blocking the UI as "busy" was the wrong signal.
  defp upstream_preflight(%Repository{}), do: :ok

  defp with_rate_limit_opts(opts, fun) when is_list(opts) and is_function(fun, 0) do
    previous = Process.get(:tarakan_skip_code_rate_limit)

    if Keyword.get(opts, :skip_rate_limit, false) do
      Process.put(:tarakan_skip_code_rate_limit, true)
    end

    try do
      fun.()
    after
      if previous do
        Process.put(:tarakan_skip_code_rate_limit, previous)
      else
        Process.delete(:tarakan_skip_code_rate_limit)
      end
    end
  end

  defp validate_commit(%{sha: sha, tree_sha: tree_sha} = commit) do
    with {:ok, sha} <- object_sha(sha),
         {:ok, tree_sha} <- object_sha(tree_sha) do
      {:ok, %{commit | sha: sha, tree_sha: tree_sha}}
    else
      _error -> {:error, :invalid_response}
    end
  end

  defp validate_commit(_commit), do: {:error, :invalid_response}

  defp validate_tree(%{sha: sha, truncated: truncated, entries: entries} = tree)
       when is_boolean(truncated) and is_list(entries) and length(entries) <= 2_000 do
    with {:ok, sha} <- object_sha(sha),
         true <- Enum.all?(entries, &valid_raw_entry?/1) do
      {:ok, %{tree | sha: sha}}
    else
      _error -> {:error, :invalid_response}
    end
  end

  defp validate_tree(%{entries: entries}) when is_list(entries), do: {:error, :tree_too_large}
  defp validate_tree(_tree), do: {:error, :invalid_response}

  defp valid_raw_entry?(%{path: path, mode: mode, type: type, sha: sha, size: size}) do
    match?({:ok, normalized} when normalized != "", RepositoryPath.normalize(path)) and
      match?({:ok, _sha}, object_sha(sha)) and valid_type_mode?(type, mode) and
      valid_entry_size?(type, size)
  end

  defp valid_raw_entry?(_entry), do: false

  defp valid_type_mode?("tree", "040000"), do: true
  defp valid_type_mode?("blob", mode) when mode in ["100644", "100755"], do: true
  defp valid_type_mode?("symlink", "120000"), do: true
  defp valid_type_mode?("submodule", "160000"), do: true
  defp valid_type_mode?(_type, _mode), do: false

  defp valid_entry_size?(type, nil) when type in ["tree", "submodule"], do: true

  defp valid_entry_size?(type, size)
       when type in ["blob", "symlink"] and is_integer(size) and size >= 0,
       do: true

  defp valid_entry_size?(_type, _size), do: false

  defp validate_blob(%{sha: sha, size: size, content: content} = blob)
       when is_integer(size) and size >= 0 and size <= @max_blob_bytes and is_binary(content) do
    with {:ok, sha} <- object_sha(sha),
         true <- byte_size(content) == size,
         :ok <- validate_text(content) do
      {:ok, %{blob | sha: sha}}
    else
      false -> {:error, :invalid_response}
      error -> error
    end
  end

  defp validate_blob(%{size: size}) when is_integer(size) and size > @max_blob_bytes,
    do: {:error, :blob_too_large}

  defp validate_blob(_blob), do: {:error, :invalid_response}

  defp validate_entry_blob_size(size) when is_integer(size) and size <= @max_blob_bytes, do: :ok
  defp validate_entry_blob_size(size) when is_integer(size), do: {:error, :blob_too_large}
  defp validate_entry_blob_size(_size), do: {:error, :invalid_response}

  defp ensure_blob_matches_entry(%{sha: sha, size: size}, %{sha: sha, size: size}), do: :ok
  defp ensure_blob_matches_entry(_blob, _entry), do: {:error, :invalid_response}

  defp validate_text(content) do
    cond do
      not String.valid?(content) ->
        {:error, :binary_blob}

      String.contains?(content, <<0>>) or
          String.match?(content, ~r/[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]/) ->
        {:error, :binary_blob}

      source_line_count(content) > @max_blob_lines ->
        {:error, :blob_too_large}

      true ->
        :ok
    end
  end

  defp source_line_count(""), do: 0
  defp source_line_count(content), do: length(:binary.matches(content, "\n")) + 1

  defp require_complete_tree(%{truncated: false}), do: :ok
  defp require_complete_tree(%{truncated: true}), do: {:error, :tree_truncated}

  defp normalize_commit_sha(sha) when is_binary(sha) do
    if Regex.match?(@full_sha, sha),
      do: {:ok, String.downcase(sha)},
      else: {:error, :invalid_commit_sha}
  end

  defp normalize_commit_sha(_sha), do: {:error, :invalid_commit_sha}

  defp object_sha(sha) when is_binary(sha) do
    if Regex.match?(@full_sha, sha),
      do: {:ok, String.downcase(sha)},
      else: {:error, :invalid_response}
  end

  defp object_sha(_sha), do: {:error, :invalid_response}

  defp join_path("", path), do: RepositoryPath.normalize(path)
  defp join_path(base, path), do: RepositoryPath.normalize(base <> "/" <> path)

  defp entry_type("tree"), do: {:ok, :tree}
  defp entry_type("blob"), do: {:ok, :blob}
  defp entry_type("symlink"), do: {:ok, :symlink}
  defp entry_type("submodule"), do: {:ok, :submodule}
  defp entry_type(_type), do: {:error, :invalid_response}

  defp entry_sort_order(:tree), do: 0
  defp entry_sort_order(_type), do: 1

  defp commit_cache_key(repository, sha) do
    if Repository.hosted?(repository),
      do: {:hosted_commit, repository.id, sha},
      else: {:github_commit, repository.github_id, sha}
  end

  defp tree_cache_key(repository, sha, recursive) do
    if Repository.hosted?(repository),
      do: {:hosted_tree, repository.id, sha, recursive},
      else: {:github_tree, repository.github_id, sha, recursive}
  end

  defp blob_cache_key(repository, sha) do
    if Repository.hosted?(repository),
      do: {:hosted_blob, repository.id, sha},
      else: {:github_blob, repository.github_id, sha}
  end

  defp cache_ttl(key, default) do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
