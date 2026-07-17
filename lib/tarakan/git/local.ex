defmodule Tarakan.Git.Local do
  @moduledoc """
  Hardened invocation of the git CLI against a local bare repository.

  Shared by the GitHub mirror cache and Tarakan-hosted repositories. Every
  invocation runs under a hard wall-clock timeout with hooks disabled, no
  global or system config, no auth prompts, and no lazy network fetches, so
  reads never touch the network and repository content is never executed.
  """

  @max_blob_bytes 512 * 1_024
  @full_sha ~r/\A[0-9a-f]{40}\z/

  @doc """
  Runs git in `dir` with the hardened environment.

  Options: `:timeout_seconds` (default 30), `:config` - extra
  `{"key", "value"}` git config pairs passed through the environment so
  values (e.g. auth headers) never appear in argv - and `:extra_env` for
  additional environment variables (e.g. `GIT_PROTOCOL`).
  """
  def run(dir, args, opts \\ []) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, 30)
    config_pairs = Keyword.get(opts, :config, [])
    extra_env = Keyword.get(opts, :extra_env, [])

    {output, status} =
      System.cmd(
        "timeout",
        ["#{timeout_seconds}", "git", "-C", dir | args],
        env: env(config_pairs) ++ extra_env,
        stderr_to_stdout: true
      )

    if status == 0, do: {:ok, output}, else: {:error, {status, output}}
  rescue
    error -> {:error, {:spawn_failed, Exception.message(error)}}
  end

  @doc """
  The hardened git environment, as `{name, value}` pairs.

  Hooks can never run in a bare repository without a checkout, but belt and
  braces. `extra_config_pairs` travel through `GIT_CONFIG_KEY_*` variables.
  """
  def env(extra_config_pairs \\ []) do
    config_pairs = [{"core.hooksPath", "/dev/null"} | extra_config_pairs]

    numbered =
      config_pairs
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, value}, index} ->
        [{"GIT_CONFIG_KEY_#{index}", key}, {"GIT_CONFIG_VALUE_#{index}", value}]
      end)

    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_NO_LAZY_FETCH", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_CONFIG_COUNT", "#{length(config_pairs)}"}
      | numbered
    ]
  end

  ## Local reads (no network, ever)

  @doc "Whether `dir` holds the given commit."
  def has_commit?(dir, commit_sha) do
    match?({:ok, _sha}, validate_sha(commit_sha)) and
      match?({:ok, _output}, read(dir, ["cat-file", "-e", "#{commit_sha}^{commit}"]))
  end

  def read_commit(dir, commit_sha) do
    with {:ok, commit_sha} <- validate_sha(commit_sha),
         {:ok, output} <- read(dir, ["cat-file", "commit", commit_sha]),
         {:ok, tree_sha} <- commit_tree_sha(output) do
      {:ok, %{sha: commit_sha, tree_sha: tree_sha, committed_at: committer_datetime(output)}}
    else
      _other -> :miss
    end
  end

  def read_tree(dir, tree_sha, recursive) when is_boolean(recursive) do
    recursion_args = if recursive, do: ["-r", "-t"], else: []

    with {:ok, tree_sha} <- validate_sha(tree_sha),
         {:ok, output} <- read(dir, ["ls-tree", "-z", "-l"] ++ recursion_args ++ [tree_sha]),
         {:ok, entries} <- parse_tree_entries(output) do
      {:ok, %{sha: tree_sha, truncated: false, entries: entries}}
    else
      _other -> :miss
    end
  end

  def read_blob(dir, blob_sha, max_bytes \\ @max_blob_bytes) do
    with {:ok, blob_sha} <- validate_sha(blob_sha),
         {:ok, content} <- read(dir, ["cat-file", "blob", blob_sha]),
         true <- byte_size(content) <= max_bytes do
      {:ok, %{sha: blob_sha, size: byte_size(content), content: content}}
    else
      _other -> :miss
    end
  end

  @doc """
  Resolves HEAD to its branch name and full commit SHA.

  Returns `:empty` for a repository whose HEAD points at an unborn branch
  (nothing pushed yet) and `:miss` when the repository cannot be read.
  """
  def head_commit(dir) do
    with {:ok, ref_output} <- read(dir, ["symbolic-ref", "HEAD"]),
         "refs/heads/" <> branch <- String.trim(ref_output) do
      case read(dir, ["rev-parse", "--verify", "HEAD^{commit}"]) do
        {:ok, sha_output} ->
          case validate_sha(String.trim(sha_output)) do
            {:ok, sha} -> {:ok, %{branch: branch, sha: sha}}
            _invalid -> :miss
          end

        {:error, _unborn} ->
          :empty
      end
    else
      _other -> :miss
    end
  end

  @doc "Lists local branch names."
  def branches(dir) do
    case read(dir, ["for-each-ref", "--format=%(refname:strip=2)", "refs/heads"]) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      _error -> :miss
    end
  end

  @doc """
  Resolves a local branch name to a full commit SHA.

  Branch names are constrained to a safe subset so they can be passed to
  `rev-parse` without shell ambiguity.
  """
  def branch_head(dir, branch) when is_binary(branch) do
    case validate_branch_name(branch) do
      {:ok, branch} ->
        case read(dir, ["rev-parse", "--verify", "refs/heads/#{branch}^{commit}"]) do
          {:ok, sha_output} ->
            case validate_sha(String.trim(sha_output)) do
              {:ok, sha} -> {:ok, sha}
              _invalid -> :miss
            end

          {:error, _reason} ->
            :miss
        end

      :error ->
        :miss
    end
  end

  def branch_head(_dir, _branch), do: :miss

  def validate_sha(sha) when is_binary(sha) do
    sha = String.downcase(sha)
    if Regex.match?(@full_sha, sha), do: {:ok, sha}, else: {:error, :invalid_reference}
  end

  def validate_sha(_sha), do: {:error, :invalid_reference}

  # Git branch names: disallow control chars, leading/trailing dots/slashes,
  # and sequences git rejects. Keep this strict for rev-parse safety.
  defp validate_branch_name(branch) do
    branch = String.trim(branch)

    cond do
      branch == "" ->
        :error

      byte_size(branch) > 250 ->
        :error

      String.contains?(branch, ["..", "@{", "\\", " ", "\t", "\n", "~", "^", ":", "?", "*", "["]) ->
        :error

      String.starts_with?(branch, "/") or String.ends_with?(branch, "/") or
          String.ends_with?(branch, ".lock") ->
        :error

      not String.valid?(branch) ->
        :error

      true ->
        {:ok, branch}
    end
  end

  defp read(dir, args) do
    if File.dir?(dir) do
      run(dir, args)
    else
      {:error, :no_repository}
    end
  end

  ## Object parsing

  defp commit_tree_sha(commit_text) do
    commit_text
    |> String.split("\n")
    |> Enum.find_value({:error, :invalid_reference}, fn line ->
      case String.split(line, " ", parts: 2) do
        ["tree", sha] -> validate_sha(sha)
        _other -> nil
      end
    end)
  end

  defp committer_datetime(commit_text) do
    commit_text
    |> String.split("\n")
    |> Enum.find_value(nil, fn line ->
      with "committer " <> rest <- line,
           [_all, epoch] <- Regex.run(~r/>\s+(\d+)\s+[+-]\d{4}\z/, rest),
           {seconds, ""} <- Integer.parse(epoch),
           {:ok, datetime} <- DateTime.from_unix(seconds) do
        datetime
      else
        _other -> nil
      end
    end)
  end

  defp parse_tree_entries(output) do
    entries =
      output
      |> String.split(<<0>>, trim: true)
      |> Enum.map(&parse_tree_entry/1)

    if Enum.all?(entries, &is_map/1) do
      {:ok, entries}
    else
      # Includes the filtered-out oversized blob case (`-l` prints no usable
      # size): fall back so the API reports the listing with real sizes.
      :error
    end
  end

  defp parse_tree_entry(line) do
    with [meta, path] <- String.split(line, "\t", parts: 2),
         [mode, type, sha, size] <- String.split(meta, " ", trim: true),
         {:ok, sha} <- validate_sha(sha),
         {:ok, size} <- entry_size(type, size) do
      %{path: path, mode: mode, type: normalize_type(type, mode), sha: sha, size: size}
    else
      _other -> :invalid
    end
  end

  defp entry_size(type, "-") when type in ["tree", "commit"], do: {:ok, nil}

  defp entry_size("blob", size) do
    case Integer.parse(size) do
      {size, ""} when size >= 0 -> {:ok, size}
      _other -> :error
    end
  end

  defp entry_size(_type, _size), do: :error

  defp normalize_type("tree", "040000"), do: "tree"
  defp normalize_type("blob", "120000"), do: "symlink"
  defp normalize_type("blob", mode) when mode in ["100644", "100755"], do: "blob"
  defp normalize_type("commit", "160000"), do: "submodule"
  defp normalize_type(type, _mode), do: type
end
