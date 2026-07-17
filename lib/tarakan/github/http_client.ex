defmodule Tarakan.GitHub.HTTPClient do
  @moduledoc false

  @behaviour Tarakan.GitHubClient

  alias Tarakan.RepositoryPath

  @api_root "https://api.github.com"
  @max_tree_entries 2_000
  @max_tree_response_bytes 2 * 1_024 * 1_024
  @max_blob_bytes 512 * 1_024
  @max_blob_lines 10_000
  @max_blob_response_bytes 800_000
  @max_metadata_response_bytes 512_000
  @max_commit_response_bytes 8 * 1_024 * 1_024
  @full_sha ~r/\A[0-9a-fA-F]{40}\z/

  @impl true
  def fetch_repository(owner, name, opts \\ []) do
    with :ok <- validate_identity(owner, name) do
      owner = encode_segment(owner)
      name = encode_segment(name)
      url = "#{@api_root}/repos/#{owner}/#{name}"

      request_repository_metadata(url, conditional_headers(opts))
    end
  end

  @impl true
  def fetch_repository_by_id(github_id) when is_integer(github_id) and github_id > 0 do
    request_repository_metadata("#{@api_root}/repositories/#{github_id}", [])
  end

  def fetch_repository_by_id(_github_id), do: {:error, :invalid_reference}

  defp request_repository_metadata(url, extra_headers) do
    case request_json(url, @max_metadata_response_bytes, extra_headers) do
      {:ok, 200, body, resp_headers} ->
        with {:ok, metadata} <- repository_metadata(body) do
          {:ok, Map.put(metadata, :etag, response_etag(resp_headers))}
        end

      {:ok, 304, _body, _resp_headers} ->
        :not_modified

      {:ok, status, _body, _resp_headers} when status in [301, 302, 307, 308] ->
        {:error, :moved}

      {:ok, 404, _body, _resp_headers} ->
        {:error, :not_found}

      {:ok, status, _body, _resp_headers} when status in [403, 429] ->
        {:error, :rate_limited}

      {:ok, _status, _body, _resp_headers} ->
        {:error, :unavailable}

      {:error, :response_too_large} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conditional_headers(opts) do
    case Keyword.get(opts, :etag) do
      etag when is_binary(etag) and etag != "" -> [{"if-none-match", etag}]
      _other -> []
    end
  end

  defp response_etag(resp_headers) when is_map(resp_headers) do
    case Map.get(resp_headers, "etag") do
      [etag | _rest] when is_binary(etag) and etag != "" -> etag
      _other -> nil
    end
  end

  defp response_etag(_resp_headers), do: nil

  @doc false
  def repository_metadata(%{"private" => false, "visibility" => "public"} = body) do
    metadata = %{
      github_id: body["id"],
      node_id: body["node_id"],
      host: "github.com",
      owner: get_in(body, ["owner", "login"]),
      name: body["name"],
      canonical_url: body["html_url"],
      default_branch: body["default_branch"],
      description: body["description"],
      primary_language: body["language"],
      stars_count: body["stargazers_count"] || 0,
      forks_count: body["forks_count"] || 0,
      archived: body["archived"] || false,
      private: false,
      visibility: "public",
      last_synced_at: DateTime.utc_now()
    }

    if valid_repository_metadata?(metadata),
      do: {:ok, metadata},
      else: {:error, :invalid_response}
  end

  def repository_metadata(_body), do: {:error, :not_public}

  @impl true
  def fetch_commit(owner, name, sha) do
    with :ok <- validate_identity(owner, name),
         {:ok, sha} <- validate_sha(sha) do
      owner = encode_segment(owner)
      name = encode_segment(name)

      case request_json(
             "#{@api_root}/repos/#{owner}/#{name}/git/commits/#{sha}",
             @max_commit_response_bytes
           ) do
        {:ok, 200, body, _resp_headers} -> commit_metadata(body)
        {:ok, status, _body, _resp_headers} when status in [404, 422] -> {:error, :not_found}
        {:ok, status, _body, _resp_headers} when status in [403, 429] -> {:error, :rate_limited}
        {:ok, _status, _body, _resp_headers} -> {:error, :unavailable}
        {:error, :response_too_large} -> {:error, :invalid_response}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def commit_metadata(body) when is_map(body) do
    with {:ok, sha} <- validate_sha(body["sha"]),
         {:ok, tree_sha} <- validate_sha(get_in(body, ["tree", "sha"])) do
      {:ok, %{sha: sha, tree_sha: tree_sha, committed_at: parse_commit_datetime(body)}}
    else
      _error -> {:error, :invalid_response}
    end
  end

  def commit_metadata(_body), do: {:error, :invalid_response}

  @impl true
  def fetch_branch_head(owner, name, branch) do
    with :ok <- validate_identity(owner, name),
         {:ok, branch} <- validate_branch(branch) do
      owner = encode_segment(owner)
      name = encode_segment(name)
      branch = encode_segment(branch)

      case request_json(
             "#{@api_root}/repos/#{owner}/#{name}/branches/#{branch}",
             @max_commit_response_bytes
           ) do
        {:ok, 200, body, _resp_headers} -> branch_metadata(body)
        {:ok, status, _body, _resp_headers} when status in [404, 422] -> {:error, :not_found}
        {:ok, status, _body, _resp_headers} when status in [403, 429] -> {:error, :rate_limited}
        {:ok, _status, _body, _resp_headers} -> {:error, :unavailable}
        {:error, :response_too_large} -> {:error, :invalid_response}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list_branches(owner, name) do
    with :ok <- validate_identity(owner, name) do
      owner = encode_segment(owner)
      name = encode_segment(name)
      # First page only — enough for typical public repos; UI can still take a raw SHA.
      url = "#{@api_root}/repos/#{owner}/#{name}/branches?per_page=100"

      case request_json(url, @max_metadata_response_bytes) do
        {:ok, 200, body, _resp_headers} when is_list(body) ->
          names =
            body
            |> Enum.map(fn
              %{"name" => branch} when is_binary(branch) -> branch
              _other -> nil
            end)
            |> Enum.reject(&is_nil/1)

          {:ok, names}

        {:ok, 200, _body, _resp_headers} ->
          {:error, :invalid_response}

        {:ok, status, _body, _resp_headers} when status in [404, 422] ->
          {:error, :not_found}

        {:ok, status, _body, _resp_headers} when status in [403, 429] ->
          {:error, :rate_limited}

        {:ok, _status, _body, _resp_headers} ->
          {:error, :unavailable}

        {:error, :response_too_large} ->
          {:error, :invalid_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def branch_metadata(%{"commit" => commit}) when is_map(commit) do
    commit_metadata(%{
      "sha" => commit["sha"],
      "tree" => get_in(commit, ["commit", "tree"]),
      "committer" => get_in(commit, ["commit", "committer"])
    })
  end

  def branch_metadata(_body), do: {:error, :invalid_response}

  @impl true
  def fetch_tree(owner, name, tree_sha, recursive) when is_boolean(recursive) do
    with :ok <- validate_identity(owner, name),
         {:ok, tree_sha} <- validate_sha(tree_sha) do
      owner = encode_segment(owner)
      name = encode_segment(name)
      query = if recursive, do: "?recursive=1", else: ""

      case request_json(
             "#{@api_root}/repos/#{owner}/#{name}/git/trees/#{tree_sha}#{query}",
             @max_tree_response_bytes
           ) do
        {:ok, 200, body, _resp_headers} -> tree_metadata(body)
        {:ok, status, _body, _resp_headers} when status in [404, 409, 422] -> {:error, :not_found}
        {:ok, status, _body, _resp_headers} when status in [403, 429] -> {:error, :rate_limited}
        {:ok, _status, _body, _resp_headers} -> {:error, :unavailable}
        {:error, :response_too_large} -> {:error, :tree_too_large}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def fetch_tree(_owner, _name, _tree_sha, _recursive), do: {:error, :invalid_reference}

  @doc false
  def tree_metadata(%{"sha" => sha, "truncated" => truncated, "tree" => entries})
      when is_boolean(truncated) and is_list(entries) do
    with {:ok, sha} <- validate_sha(sha),
         :ok <- validate_tree_count(entries),
         {:ok, entries} <- parse_tree_entries(entries) do
      {:ok, %{sha: sha, truncated: truncated, entries: entries}}
    else
      {:error, :tree_too_large} = error -> error
      _error -> {:error, :invalid_response}
    end
  end

  def tree_metadata(_body), do: {:error, :invalid_response}

  @impl true
  def fetch_text_blob(owner, name, blob_sha) do
    with :ok <- validate_identity(owner, name),
         {:ok, blob_sha} <- validate_sha(blob_sha) do
      owner = encode_segment(owner)
      name = encode_segment(name)

      case request_json(
             "#{@api_root}/repos/#{owner}/#{name}/git/blobs/#{blob_sha}",
             @max_blob_response_bytes
           ) do
        {:ok, 200, body, _resp_headers} -> blob_metadata(body)
        {:ok, status, _body, _resp_headers} when status in [404, 409, 422] -> {:error, :not_found}
        {:ok, status, _body, _resp_headers} when status in [403, 429] -> {:error, :rate_limited}
        {:ok, _status, _body, _resp_headers} -> {:error, :unavailable}
        {:error, :response_too_large} -> {:error, :blob_too_large}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def blob_metadata(%{
        "sha" => sha,
        "size" => size,
        "encoding" => "base64",
        "content" => encoded
      })
      when is_integer(size) and size >= 0 and is_binary(encoded) do
    with {:ok, sha} <- validate_sha(sha),
         :ok <- validate_blob_size(size),
         :ok <- validate_encoded_size(encoded),
         {:ok, content} <- decode_blob(encoded),
         :ok <- validate_decoded_size(content, size),
         :ok <- validate_text(content) do
      {:ok, %{sha: sha, size: size, content: content}}
    else
      {:error, reason} when reason in [:blob_too_large, :binary_blob] -> {:error, reason}
      _error -> {:error, :invalid_response}
    end
  end

  def blob_metadata(_body), do: {:error, :invalid_response}

  defp request_json(url, max_bytes, extra_headers \\ []) do
    into = fn {:data, data}, {request, response} ->
      case append_chunk(response.body, data, max_bytes) do
        {:ok, body} -> {:cont, {request, %{response | body: body}}}
        :too_large -> {:halt, {request, %{response | body: :response_too_large}}}
      end
    end

    case Req.get(url,
           headers: headers() ++ extra_headers,
           raw: true,
           redirect: false,
           retry: false,
           receive_timeout: 15_000,
           into: into
         ) do
      {:ok, %{body: :response_too_large}} ->
        {:error, :response_too_large}

      {:ok, %{status: status, body: body, headers: resp_headers}}
      when is_integer(status) and status == 200 ->
        with {:ok, encoded} <- collected_body(body),
             {:ok, decoded} <- Jason.decode(encoded) do
          {:ok, status, decoded, resp_headers}
        else
          _error -> {:error, :invalid_response}
        end

      {:ok, %{status: status, headers: resp_headers}} when is_integer(status) ->
        {:ok, status, nil, resp_headers}

      {:error, _exception} ->
        {:error, :unavailable}
    end
  end

  defp append_chunk("", data, max_bytes), do: append_chunk({:chunks, 0, []}, data, max_bytes)

  defp append_chunk({:chunks, size, chunks}, data, max_bytes)
       when is_binary(data) and size + byte_size(data) <= max_bytes do
    {:ok, {:chunks, size + byte_size(data), [data | chunks]}}
  end

  defp append_chunk(_body, _data, _max_bytes), do: :too_large

  defp collected_body(""), do: {:ok, ""}

  defp collected_body({:chunks, _size, chunks}) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp collected_body(_body), do: {:error, :invalid_response}

  defp parse_tree_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, parsed} ->
      case parse_tree_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_tree_entry(
         %{
           "path" => path,
           "mode" => mode,
           "type" => raw_type,
           "sha" => sha
         } = entry
       )
       when is_binary(mode) do
    with {:ok, path} <- RepositoryPath.normalize(path),
         false <- path == "",
         {:ok, sha} <- validate_sha(sha),
         {:ok, type} <- normalize_entry_type(raw_type, mode),
         {:ok, size} <- normalize_entry_size(type, entry["size"]) do
      {:ok, %{path: path, mode: mode, type: type, sha: sha, size: size}}
    else
      _error -> {:error, :invalid_response}
    end
  end

  defp parse_tree_entry(_entry), do: {:error, :invalid_response}

  defp normalize_entry_type("tree", "040000"), do: {:ok, "tree"}
  defp normalize_entry_type("blob", "120000"), do: {:ok, "symlink"}
  defp normalize_entry_type("blob", mode) when mode in ["100644", "100755"], do: {:ok, "blob"}
  defp normalize_entry_type("commit", "160000"), do: {:ok, "submodule"}
  defp normalize_entry_type(_type, _mode), do: {:error, :invalid_response}

  defp normalize_entry_size("blob", size) when is_integer(size) and size >= 0, do: {:ok, size}
  defp normalize_entry_size("symlink", size) when is_integer(size) and size >= 0, do: {:ok, size}
  defp normalize_entry_size(type, nil) when type in ["tree", "submodule"], do: {:ok, nil}
  defp normalize_entry_size(_type, _size), do: {:error, :invalid_response}

  defp validate_tree_count(entries) do
    if length(entries) <= @max_tree_entries, do: :ok, else: {:error, :tree_too_large}
  end

  defp validate_blob_size(size) do
    if size <= @max_blob_bytes, do: :ok, else: {:error, :blob_too_large}
  end

  defp validate_encoded_size(encoded) do
    if byte_size(encoded) <= @max_blob_response_bytes,
      do: :ok,
      else: {:error, :blob_too_large}
  end

  defp decode_blob(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :invalid_response}
    end
  end

  defp validate_decoded_size(content, size) do
    if byte_size(content) == size, do: :ok, else: {:error, :invalid_response}
  end

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

  defp validate_identity(owner, name) when is_binary(owner) and is_binary(name) do
    if Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?\z/, owner) and
         Regex.match?(~r/\A[a-zA-Z0-9._-]{1,100}\z/, name) do
      :ok
    else
      {:error, :invalid_reference}
    end
  end

  defp validate_identity(_owner, _name), do: {:error, :invalid_reference}

  defp validate_branch(branch) when is_binary(branch) do
    if branch != "" and byte_size(branch) <= 500 and String.valid?(branch) and
         not String.match?(branch, ~r/[\x00-\x1F\x7F]/) do
      {:ok, branch}
    else
      {:error, :invalid_reference}
    end
  end

  defp validate_branch(_branch), do: {:error, :invalid_reference}

  defp validate_sha(sha) when is_binary(sha) do
    if Regex.match?(@full_sha, sha),
      do: {:ok, String.downcase(sha)},
      else: {:error, :invalid_reference}
  end

  defp validate_sha(_sha), do: {:error, :invalid_reference}

  defp valid_repository_metadata?(metadata) do
    is_integer(metadata.github_id) and metadata.github_id > 0 and
      is_binary(metadata.owner) and metadata.owner != "" and
      is_binary(metadata.name) and metadata.name != "" and
      is_binary(metadata.canonical_url) and metadata.canonical_url != "" and
      is_binary(metadata.default_branch) and metadata.default_branch != ""
  end

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp headers do
    github_config = Application.fetch_env!(:tarakan, :github)

    base_headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "Tarakan/0.1 (https://tarakan.lol)"},
      {"x-github-api-version", Keyword.fetch!(github_config, :api_version)}
    ]

    case github_config[:api_token] do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"} | base_headers]

      _other ->
        base_headers
    end
  end

  defp parse_commit_datetime(body) do
    with date when is_binary(date) <- get_in(body, ["committer", "date"]),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(date) do
      datetime
    else
      _other -> nil
    end
  end
end
