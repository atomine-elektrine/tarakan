defmodule TarakanWeb.RepositoryCodeLive do
  use TarakanWeb, :live_view

  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryCode
  alias Tarakan.RepositoryCode.{File, Tree}
  alias Tarakan.RepositoryPath
  alias Tarakan.Scans
  alias TarakanWeb.RepositoryPaths

  @commit_sha_pattern ~r/^[0-9a-f]{40}$/
  @line_range_pattern ~r/^([1-9][0-9]{0,8})(?:-([1-9][0-9]{0,8}))?$/
  @max_rendered_lines 10_000
  @max_selected_line 1_000_000
  @max_selected_span 1_000

  @impl true
  def mount(params, _session, socket) do
    {action, params} = normalize_route_params(socket.assigns.live_action, params)
    socket = assign(socket, :live_action, action)

    case source_from_params(action, params, socket) do
      {:ok, source} ->
        repository = source.repository

        if connected?(socket) do
          Repositories.subscribe()
          Scans.subscribe(repository.id)
        end

        {:ok,
         socket
         |> assign(:page_title, "Code · #{repository.owner}/#{repository.name}")
         |> assign(:repository, repository)
         |> assign(:clone_urls, RepositoryPaths.clone_urls(repository))
         |> assign(:finding, source.finding)
         |> assign(:finding_ref, source.finding && source.finding.public_id)
         |> assign(:source_commit_sha, source.commit_sha)
         |> assign(:source_path, source.path)
         |> assign(:source_line_range, source.line_range)
         |> assign(:commit_sha, nil)
         |> assign(:path, "")
         |> assign(:path_segments, [])
         |> assign(:line_range, nil)
         |> assign(:line_range_invalid?, false)
         |> assign(:view_state, :loading)
         |> assign(:browser_kind, nil)
         |> assign(:tree, nil)
         |> assign(:file, nil)
         |> assign(:entry_count, 0)
         |> assign(:visible_finding_count, 0)
         |> assign(:line_count, 0)
         |> assign(:line_range_outside_file?, false)
         |> assign(:suspicious_controls?, false)
         |> assign(:error_kind, nil)
         |> assign(:request_id, nil)
         |> assign(:branch_options, [])
         |> assign(:selected_branch, repository.default_branch)
         |> maybe_load_branch_options(action)
         |> stream_configure(:entries, dom_id: &entry_dom_id/1)
         |> stream_configure(:lines, dom_id: &line_dom_id/1)
         |> stream(:entries, [])
         |> stream(:lines, [])}

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: Repository
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {action, params} = normalize_route_params(socket.assigns.live_action, params)

    socket =
      case action do
        :entry -> prepare_entry_request(socket)
        :finding -> prepare_finding_request(socket)
        :show -> prepare_code_request(socket, params)
      end

    {:noreply, maybe_start_request(assign(socket, :live_action, action))}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    {:noreply,
     socket
     |> assign(:view_state, :loading)
     |> assign(:error_kind, nil)
     |> maybe_start_request()}
  end

  # Switch the code browser to another branch tip (still commit-pinned under the hood).
  def handle_event("select_branch", %{"branch" => branch}, socket) do
    if socket.assigns.live_action == :finding do
      {:noreply, put_flash(socket, :error, "Finding context is pinned to its report commit.")}
    else
      repository = socket.assigns.repository
      branch = String.trim(to_string(branch || ""))

      case RepositoryCode.resolve_branch_commit(repository, branch) do
        {:ok, commit_sha} ->
          path =
            if is_binary(socket.assigns.path) and socket.assigns.path != "" do
              split_path(socket.assigns.path)
            else
              []
            end

          {:noreply,
           socket
           |> assign(:selected_branch, branch)
           |> push_navigate(to: code_path(repository, commit_sha, path))}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not resolve branch #{inspect(branch)} to a commit.")}
      end
    end
  end

  @impl true
  def handle_async(:browse, {:ok, {request_id, result}}, socket) do
    if request_id == socket.assigns.request_id do
      case reauthorize_view(socket) do
        {:ok, authorized_socket} ->
          {:noreply, apply_browse_result(authorized_socket, result)}

        {:error, :not_found} ->
          {:noreply, evict_source(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:browse, {:exit, _reason}, socket) do
    {:noreply, assign_error(socket, :unavailable)}
  end

  @impl true
  def handle_info(
        {:repository_record_updated, %Repository{id: repository_id}},
        %{assigns: %{repository: %Repository{id: repository_id}}} = socket
      ) do
    case reauthorize_view(socket) do
      {:ok, authorized_socket} -> {:noreply, refresh_finding_badges(authorized_socket)}
      {:error, :not_found} -> {:noreply, evict_source(socket)}
    end
  end

  def handle_info({event, %Repository{}}, socket)
      when event in [:repository_registered, :repository_record_updated] do
    {:noreply, socket}
  end

  def handle_info(
        {:scan_updated, %{id: scan_id}},
        %{assigns: %{live_action: :finding, finding: %{scan_id: scan_id}}} = socket
      ) do
    case reauthorize_view(socket) do
      {:ok, authorized_socket} -> {:noreply, authorized_socket}
      {:error, :not_found} -> {:noreply, evict_source(socket)}
    end
  end

  def handle_info({event, _scan}, socket) when event in [:scan_submitted, :scan_updated],
    do: {:noreply, refresh_finding_badges(socket)}

  defp source_from_params(:finding, %{"finding_ref" => finding_ref}, socket) do
    with {:ok, {scan, finding}} <- Scans.get_finding(socket.assigns.current_scope, finding_ref),
         %Repository{} = repository <-
           Repositories.get_visible_repository(
             scan.repository.host,
             scan.repository.owner,
             scan.repository.name,
             socket.assigns.current_scope
           ) do
      {:ok,
       %{
         repository: repository,
         finding: finding,
         commit_sha: scan.commit_sha,
         path: finding.file_path,
         line_range: finding_line_range(finding)
       }}
    end
  end

  defp source_from_params(_action, %{"host" => slug, "owner" => owner, "name" => name}, socket) do
    with {:ok, host} <- Tarakan.Hosts.host_for_slug(slug),
         %Repository{} = repository <-
           Repositories.get_visible_repository(host, owner, name, socket.assigns.current_scope) do
      {:ok,
       %{
         repository: repository,
         finding: nil,
         commit_sha: nil,
         path: nil,
         line_range: nil
       }}
    else
      _not_visible -> {:error, :not_found}
    end
  end

  defp source_from_params(_action, _params, _socket), do: {:error, :not_found}

  # Resolves the bare GitHub-style routes (/owner/name...), which carry no
  # :host segment. A handle-like first segment is a Tarakan-hosted
  # repository. A host-like first segment means the bare pattern's literal
  # ("code") swallowed a remote path - a repository literally named "code" -
  # so shift the params: /github.com/rails/code[/code[/sha[/*path]]].
  # The security tab of such a repository has no reachable URL form; those
  # requests fall through to :not_found.
  defp normalize_route_params(action, %{"owner" => owner, "name" => name} = params)
       when not is_map_key(params, "host") do
    if Tarakan.Hosts.host_segment?(owner) do
      remote = %{"host" => owner, "owner" => name, "name" => "code"}

      case {action, params["commit_sha"], params["path"]} do
        {:code_entry, _sha, _path} ->
          {:entry, remote}

        {:show, "code", nil} ->
          {:entry, remote}

        {:show, "code", [commit_sha | path]} ->
          {:show, remote |> Map.put("commit_sha", commit_sha) |> Map.put("path", path)}

        _other ->
          {action, params}
      end
    else
      {action_without_code_alias(action), Map.put(params, "host", Repository.hosted_host())}
    end
  end

  defp normalize_route_params(action, params), do: {action_without_code_alias(action), params}

  # /:owner/:name/code is a distinct live action only so bare-route
  # reinterpretation can tell it apart from /:owner/:name; everywhere else
  # it behaves exactly like :entry.
  defp action_without_code_alias(:code_entry), do: :entry
  defp action_without_code_alias(action), do: action

  defp prepare_entry_request(socket) do
    prepare_request(socket, :resolve_entry, nil, "", nil, false)
  end

  defp prepare_finding_request(socket) do
    prepare_request(
      socket,
      :browse_finding,
      socket.assigns.source_commit_sha,
      socket.assigns.source_path,
      socket.assigns.source_line_range,
      false
    )
  end

  defp prepare_code_request(socket, params) do
    with {:ok, commit_sha} <- normalize_commit_sha(params["commit_sha"]),
         {:ok, path} <- normalize_route_path(params["path"]),
         {:ok, line_range, line_range_invalid?} <- parse_line_range(params["lines"]) do
      prepare_request(
        socket,
        :browse,
        commit_sha,
        path,
        line_range,
        line_range_invalid?
      )
    else
      {:error, reason} -> assign_error(socket, reason)
    end
  end

  defp prepare_request(
         socket,
         request_kind,
         commit_sha,
         path,
         line_range,
         line_range_invalid?
       ) do
    request_id = System.unique_integer([:positive, :monotonic])

    socket
    |> assign(:request_id, request_id)
    |> assign(:request_kind, request_kind)
    |> assign(:commit_sha, commit_sha)
    |> assign(:path, path)
    |> assign(:path_segments, split_path(path))
    |> assign(:line_range, line_range)
    |> assign(:line_range_invalid?, line_range_invalid?)
    |> assign(:view_state, :loading)
    |> assign(:browser_kind, nil)
    |> assign(:tree, nil)
    |> assign(:file, nil)
    |> assign(:entry_count, 0)
    |> assign(:visible_finding_count, 0)
    |> assign(:line_count, 0)
    |> assign(:line_range_outside_file?, false)
    |> assign(:suspicious_controls?, false)
    |> assign(:error_kind, nil)
    |> stream(:entries, [], reset: true)
    |> stream(:lines, [], reset: true)
  end

  defp maybe_start_request(%{assigns: %{view_state: :loading}} = socket) do
    if connected?(socket) do
      request_id = socket.assigns.request_id
      request_kind = socket.assigns.request_kind
      repository = socket.assigns.repository
      commit_sha = socket.assigns.commit_sha
      path = socket.assigns.path
      # Always skip Tarakan-side code budgets; objects come from git mirrors.
      skip_rate_limit = true

      socket
      |> cancel_async(:browse)
      |> start_async(:browse, fn ->
        {request_id, run_request(request_kind, repository, commit_sha, path, skip_rate_limit)}
      end)
    else
      socket
    end
  end

  defp maybe_start_request(socket), do: socket

  defp run_request(:browse, repository, commit_sha, path, skip_rate_limit) do
    opts = code_opts(skip_rate_limit)

    with {:ok, current_commit_sha} <- RepositoryCode.resolve_default_commit(repository, opts),
         true <- Plug.Crypto.secure_compare(current_commit_sha, commit_sha),
         {:ok, result} <- RepositoryCode.browse(repository, commit_sha, path, opts) do
      {:ok, result}
    else
      false -> {:error, :not_found}
      # Never show the old "busy network" page for GitHub REST quota.
      {:error, :rate_limited} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_request(:browse_finding, repository, commit_sha, path, skip_rate_limit) do
    case RepositoryCode.browse(repository, commit_sha, path, code_opts(skip_rate_limit)) do
      {:error, :rate_limited} -> {:error, :unavailable}
      other -> other
    end
  end

  defp run_request(:resolve_entry, repository, _commit_sha, _path, skip_rate_limit) do
    opts = code_opts(skip_rate_limit)

    with {:ok, commit_sha} <- RepositoryCode.resolve_default_commit(repository, opts),
         {:ok, result} <- RepositoryCode.browse(repository, commit_sha, "", opts) do
      {:ok, result}
    else
      {:error, :rate_limited} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp code_opts(true), do: [skip_rate_limit: true]
  defp code_opts(false), do: []

  defp apply_browse_result(socket, {:ok, %Tree{truncated: true}}) do
    assign_error(socket, :tree_truncated)
  end

  defp apply_browse_result(socket, {:ok, %Tree{} = tree}) do
    finding_paths = visible_finding_paths(socket, tree.commit_sha)

    entries =
      tree.entries
      |> sort_entries()
      |> Enum.map(&entry_with_finding_count(&1, finding_paths))

    socket
    |> assign(:view_state, :ready)
    |> assign(:browser_kind, :tree)
    |> assign(:commit_sha, tree.commit_sha)
    |> assign(:path, tree.path)
    |> assign(:path_segments, split_path(tree.path))
    |> assign(:tree, tree)
    |> assign(:file, nil)
    |> assign(:entry_count, length(entries))
    |> assign(:visible_finding_count, length(finding_paths))
    |> assign(:line_count, 0)
    |> assign(:line_range_outside_file?, false)
    |> assign(:suspicious_controls?, false)
    |> assign(:error_kind, nil)
    |> stream(:entries, entries, reset: true)
    |> stream(:lines, [], reset: true)
  end

  defp apply_browse_result(socket, {:ok, %File{} = file}) do
    case file_lines(file.content, socket.assigns.line_range) do
      {:ok, lines} ->
        line_count = length(lines)
        finding_count = visible_file_finding_count(socket, file.commit_sha, file.path)

        socket
        |> assign(:view_state, :ready)
        |> assign(:browser_kind, :file)
        |> assign(:commit_sha, file.commit_sha)
        |> assign(:path, file.path)
        |> assign(:path_segments, split_path(file.path))
        |> assign(:tree, nil)
        |> assign(:file, file)
        |> assign(:entry_count, 0)
        |> assign(:visible_finding_count, finding_count)
        |> assign(:line_count, line_count)
        |> assign(
          :line_range_outside_file?,
          line_range_outside_file?(socket.assigns.line_range, line_count)
        )
        |> assign(:suspicious_controls?, suspicious_source_controls?(file.content))
        |> assign(:error_kind, nil)
        |> stream(:entries, [], reset: true)
        |> stream(:lines, lines, reset: true)

      {:error, :too_many_lines} ->
        assign_error(socket, :blob_too_large)
    end
  end

  defp apply_browse_result(socket, {:ok, commit_sha}) when is_binary(commit_sha) do
    case normalize_commit_sha(commit_sha) do
      {:ok, commit_sha} ->
        push_navigate(socket,
          to: code_path(socket.assigns.repository, commit_sha, [])
        )

      {:error, _reason} ->
        assign_error(socket, :invalid_response)
    end
  end

  defp apply_browse_result(socket, {:error, reason}), do: assign_error(socket, reason)
  defp apply_browse_result(socket, _unexpected), do: assign_error(socket, :invalid_response)

  defp assign_error(socket, reason) do
    socket
    |> assign(:view_state, :error)
    |> assign(:browser_kind, nil)
    |> assign(:tree, nil)
    |> assign(:file, nil)
    |> assign(:entry_count, 0)
    |> assign(:visible_finding_count, 0)
    |> assign(:line_count, 0)
    |> assign(:line_range_outside_file?, false)
    |> assign(:suspicious_controls?, false)
    |> assign(:error_kind, normalize_error(reason))
    |> stream(:entries, [], reset: true)
    |> stream(:lines, [], reset: true)
  end

  defp normalize_error(reason)
       when reason in [
              :invalid_commit_sha,
              :invalid_path,
              :empty_repository,
              :identity_changed,
              :commit_mismatch,
              :not_found,
              :tree_truncated,
              :tree_too_large,
              :blob_too_large,
              :binary_blob,
              :unsupported_entry,
              :rate_limited,
              :unavailable,
              :invalid_response
            ],
       do: reason

  defp normalize_error(_reason), do: :unavailable

  defp normalize_commit_sha(commit_sha) when is_binary(commit_sha) do
    normalized = String.downcase(commit_sha)

    if Regex.match?(@commit_sha_pattern, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_commit_sha}
    end
  end

  defp normalize_commit_sha(_commit_sha), do: {:error, :invalid_commit_sha}

  defp normalize_route_path(nil), do: {:ok, ""}

  defp normalize_route_path(path) when is_list(path) do
    path
    |> Enum.join("/")
    |> RepositoryPath.normalize()
  end

  defp normalize_route_path(_path), do: {:error, :invalid_path}

  defp parse_line_range(nil), do: {:ok, nil, false}
  defp parse_line_range(""), do: {:ok, nil, false}

  defp parse_line_range(value) when is_binary(value) do
    case Regex.run(@line_range_pattern, value, capture: :all_but_first) do
      [first, ""] -> validate_single_line(first)
      [first] -> validate_single_line(first)
      [first, last] -> validate_line_range(String.to_integer(first), String.to_integer(last))
      nil -> {:ok, nil, true}
    end
  end

  defp parse_line_range(_value), do: {:ok, nil, true}

  defp validate_single_line(line) do
    line = String.to_integer(line)
    validate_line_range(line, line)
  end

  defp validate_line_range(first, last)
       when last >= first and last <= @max_selected_line and
              last - first <= @max_selected_span,
       do: {:ok, {first, last}, false}

  defp validate_line_range(_first, _last), do: {:ok, nil, true}

  defp finding_line_range(%{line_start: line_start, line_end: line_end})
       when is_integer(line_start) do
    {line_start, line_end || line_start}
  end

  defp finding_line_range(_finding), do: nil

  defp split_path(""), do: []
  defp split_path(path), do: String.split(path, "/", trim: true)

  defp file_lines("", _line_range), do: {:ok, []}

  defp file_lines(content, line_range) do
    lines = String.split(content, "\n", parts: @max_rendered_lines + 1, trim: false)

    if length(lines) > @max_rendered_lines do
      {:error, :too_many_lines}
    else
      {:ok,
       lines
       |> Enum.with_index(1)
       |> Enum.map(fn {content, number} ->
         %{number: number, content: content, highlighted?: line_selected?(number, line_range)}
       end)}
    end
  end

  defp line_selected?(_number, nil), do: false
  defp line_selected?(number, {first, last}), do: number >= first and number <= last

  defp line_range_outside_file?(nil, _line_count), do: false

  defp line_range_outside_file?({first, last}, line_count),
    do: first > line_count or last > line_count

  defp sort_entries(entries) do
    Enum.sort_by(entries, fn entry ->
      {entry_type_order(entry.type), String.downcase(entry.name), entry.name}
    end)
  end

  defp entry_with_finding_count(entry, finding_paths) do
    count =
      case entry.type do
        :tree ->
          prefix = entry.path <> "/"
          Enum.count(finding_paths, &String.starts_with?(&1, prefix))

        :blob ->
          Enum.count(finding_paths, &(&1 == entry.path))

        _unsupported ->
          0
      end

    entry
    |> Map.from_struct()
    |> Map.put(:finding_count, count)
  end

  defp visible_file_finding_count(socket, commit_sha, path) do
    socket
    |> visible_finding_paths(commit_sha)
    |> Enum.count(&(&1 == path))
  end

  defp visible_finding_paths(socket, commit_sha) do
    socket.assigns.current_scope
    |> Scans.list_scans(socket.assigns.repository)
    |> Enum.filter(
      &(&1.commit_sha == commit_sha and &1.details_visible and &1.review_status != "rejected")
    )
    |> Enum.flat_map(& &1.findings)
    |> Enum.map(& &1.file_path)
  end

  defp refresh_finding_badges(%{assigns: %{browser_kind: :tree, tree: %Tree{} = tree}} = socket),
    do: apply_browse_result(socket, {:ok, tree})

  defp refresh_finding_badges(%{assigns: %{browser_kind: :file, file: %File{} = file}} = socket) do
    assign(
      socket,
      :visible_finding_count,
      visible_file_finding_count(socket, file.commit_sha, file.path)
    )
  end

  defp refresh_finding_badges(socket), do: socket

  defp entry_type_order(:tree), do: 0
  defp entry_type_order(:blob), do: 1
  defp entry_type_order(:symlink), do: 2
  defp entry_type_order(:submodule), do: 3

  defp entry_dom_id(entry) do
    encoded_path = Base.url_encode64(entry.path, padding: false)
    "code-entry-#{encoded_path}"
  end

  defp line_dom_id(line), do: "L#{line.number}"

  defp repository_record_path(repository), do: RepositoryPaths.repository_path(repository)

  defp repository_security_path(repository),
    do: RepositoryPaths.repository_security_path(repository)

  defp code_path(repository, commit_sha, path_segments),
    do: RepositoryPaths.repository_code_path(repository, commit_sha, path_segments)

  # Finding views stay on their report pin; free browse can switch branches.
  defp maybe_load_branch_options(socket, :finding), do: socket

  defp maybe_load_branch_options(socket, _action) do
    repository = socket.assigns.repository

    case RepositoryCode.list_branches(repository) do
      {:ok, branches} ->
        socket
        |> assign(:branch_options, branches)
        |> assign(
          :selected_branch,
          socket.assigns.selected_branch || repository.default_branch || List.first(branches)
        )

      {:error, _} ->
        default = repository.default_branch
        branches = if is_binary(default) and default != "", do: [default], else: []

        socket
        |> assign(:branch_options, branches)
        |> assign(:selected_branch, default)
    end
  end

  defp breadcrumb_items(path_segments) do
    path_segments
    |> Enum.with_index()
    |> Enum.map(fn {name, index} ->
      %{name: name, segments: Enum.take(path_segments, index + 1)}
    end)
  end

  defp entry_path(repository, commit_sha, entry) do
    code_path(repository, commit_sha, split_path(entry.path))
  end

  defp breadcrumb_path(repository, commit_sha, segments) do
    code_path(repository, commit_sha, segments)
  end

  defp line_path(live_action, finding_ref, repository, commit_sha, path_segments, line_number) do
    base =
      if live_action == :finding do
        ~p"/findings/#{finding_ref}/code"
      else
        code_path(repository, commit_sha, path_segments)
      end

    if live_action == :finding do
      base <> "#L#{line_number}"
    else
      base <> "?lines=#{line_number}#L#{line_number}"
    end
  end

  defp format_bytes(nil), do: "-"
  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1_024 * 1_024,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1_024 * 1_024), 1)} MB"

  defp short_sha(sha), do: String.slice(sha, 0, 7)

  defp entry_icon(:tree), do: "hero-folder"
  defp entry_icon(:blob), do: "hero-document-text"
  defp entry_icon(:symlink), do: "hero-link"
  defp entry_icon(:submodule), do: "hero-cube"

  defp entry_label(:symlink), do: "symbolic link"
  defp entry_label(:submodule), do: "submodule"

  defp error_title(:invalid_commit_sha), do: "Invalid commit"
  defp error_title(:invalid_path), do: "Invalid path"
  defp error_title(:not_found), do: "Source not found"
  defp error_title(:binary_blob), do: "Binary file"
  defp error_title(:blob_too_large), do: "File too large"
  defp error_title(:tree_too_large), do: "Directory too large"
  defp error_title(:tree_truncated), do: "Incomplete directory"
  defp error_title(:unsupported_entry), do: "Unsupported source entry"
  defp error_title(:empty_repository), do: "Empty repository"
  defp error_title(:rate_limited), do: "Code unavailable"
  defp error_title(:identity_changed), do: "Repository identity changed"
  defp error_title(:commit_mismatch), do: "Commit verification failed"
  defp error_title(_error), do: "Code unavailable"

  defp error_message(:invalid_commit_sha),
    do: "Code views require a full 40-character commit SHA."

  defp error_message(:invalid_path), do: "That repository path is not valid."

  defp error_message(:not_found),
    do: "No source exists at this path in the pinned commit."

  defp error_message(:binary_blob),
    do: "Tarakan does not render binary files as source code."

  defp error_message(:blob_too_large),
    do: "This file exceeds the safe source-preview limit."

  defp error_message(reason) when reason in [:tree_too_large, :tree_truncated],
    do: "This directory cannot be represented safely as a complete listing."

  defp error_message(:unsupported_entry),
    do: "This Git object type cannot be opened in the source browser."

  defp error_message(:empty_repository),
    do: "Nothing has been pushed to this repository yet. Push a branch and it will appear here."

  defp error_message(:rate_limited),
    do:
      "Could not load this commit from git or GitHub yet. Wait a few seconds for the mirror to fill, then retry."

  defp error_message(:unavailable),
    do:
      "Could not load this commit from git or GitHub yet. Wait a few seconds for the mirror to fill, then retry."

  defp error_message(reason) when reason in [:identity_changed, :commit_mismatch],
    do: "Tarakan could not verify this source against the registered public repository."

  defp error_message(_error),
    do:
      "Could not load this commit from git or GitHub yet. Wait a few seconds for the mirror to fill, then retry."

  defp suspicious_source_controls?(content) do
    String.contains?(content, <<0>>) or
      Enum.any?([0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069], fn
        codepoint -> String.contains?(content, <<codepoint::utf8>>)
      end)
  end

  defp reauthorize_view(%{assigns: %{live_action: :finding}} = socket) do
    repository = socket.assigns.repository

    with %Repository{} = visible_repository <-
           Repositories.get_visible_repository(
             repository.host,
             repository.owner,
             repository.name,
             socket.assigns.current_scope
           ),
         {:ok, {scan, finding}} <-
           Scans.get_finding(socket.assigns.current_scope, socket.assigns.finding_ref),
         true <- scan.repository_id == visible_repository.id,
         true <- scan.commit_sha == socket.assigns.source_commit_sha,
         true <- finding.file_path == socket.assigns.source_path do
      {:ok,
       socket
       |> assign(:repository, visible_repository)
       |> assign(:finding, finding)}
    else
      _not_visible -> {:error, :not_found}
    end
  end

  defp reauthorize_view(socket) do
    repository = socket.assigns.repository

    case Repositories.get_visible_repository(
           repository.host,
           repository.owner,
           repository.name,
           socket.assigns.current_scope
         ) do
      %Repository{} = visible_repository ->
        {:ok, assign(socket, :repository, visible_repository)}

      nil ->
        {:error, :not_found}
    end
  end

  defp evict_source(socket) do
    repository = socket.assigns.repository

    destination =
      case Repositories.get_visible_repository(
             repository.host,
             repository.owner,
             repository.name,
             socket.assigns.current_scope
           ) do
        %Repository{} = visible_repository -> repository_record_path(visible_repository)
        nil -> ~p"/"
      end

    socket
    |> clear_source()
    |> push_navigate(to: destination)
  end

  defp clear_source(socket) do
    socket
    |> assign(:view_state, :loading)
    |> assign(:browser_kind, nil)
    |> assign(:commit_sha, nil)
    |> assign(:path, "")
    |> assign(:path_segments, [])
    |> assign(:line_range, nil)
    |> assign(:finding, nil)
    |> assign(:tree, nil)
    |> assign(:file, nil)
    |> assign(:entry_count, 0)
    |> assign(:visible_finding_count, 0)
    |> assign(:line_count, 0)
    |> assign(:line_range_outside_file?, false)
    |> assign(:suspicious_controls?, false)
    |> assign(:error_kind, nil)
    |> stream(:entries, [], reset: true)
    |> stream(:lines, [], reset: true)
  end
end
