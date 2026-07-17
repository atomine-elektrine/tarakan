defmodule TarakanWeb.RepositoryLive.Show do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts
  alias Tarakan.Repositories
  alias Tarakan.FindingMemory
  alias Tarakan.Repositories.Repository
  alias Tarakan.RepositoryCode
  alias Tarakan.Policy
  alias Tarakan.Reputation
  alias Tarakan.Scans
  alias Tarakan.Work
  alias Tarakan.Work.ReviewTask

  @impl true
  # Bare GitHub-style routes (/owner/name/security) carry no host segment.
  # A host-like first segment means the literal "security" swallowed a
  # remote path - a repository literally named "security" - whose record
  # entry lives at the /code form, which routes unambiguously.
  def mount(%{"owner" => owner, "name" => name} = params, session, socket)
      when not is_map_key(params, "host") do
    if Tarakan.Hosts.host_segment?(owner) do
      {:ok, push_navigate(socket, to: "/#{owner}/#{name}/security/code")}
    else
      mount(Map.put(params, "host", Repository.hosted_host()), session, socket)
    end
  end

  def mount(%{"host" => slug, "owner" => owner, "name" => name}, _session, socket) do
    repository =
      with {:ok, host} <- Tarakan.Hosts.host_for_slug(slug),
           %Repository{} = repository <-
             Repositories.get_visible_repository(host, owner, name, socket.assigns.current_scope) do
        repository
      else
        _not_visible -> raise Ecto.NoResultsError, queryable: Repository
      end

    if connected?(socket) do
      Repositories.subscribe()
      Scans.subscribe(repository.id)
      Work.subscribe(repository.id)
      Reputation.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "#{repository.owner}/#{repository.name} security")
     |> assign(
       :meta_description,
       repository_meta_description(repository)
     )
     |> assign(
       :canonical_path,
       TarakanWeb.RepositoryPaths.repository_security_path(repository)
     )
     |> assign(:repository, repository)
     |> assign(:task_form, empty_task_form(repository))
     |> assign(:show_task_form, false)
     |> assign(:task_kind_options, task_kind_options())
     |> assign(:capability_options, capability_options())
     |> assign(:branch_options, [])
     |> assign(:selected_branch, repository.default_branch)
     |> assign(:can_auto_open_job, can_auto_open_job?(socket, repository))
     |> assign(:moderation_form, moderation_form())
     |> assign(:can_vote, can_vote?(socket))
     |> assign(
       :canonical_findings,
       canonical_findings(repository, socket.assigns.current_scope, current_account_id(socket))
     )
     |> stream(:tasks, Work.list_tasks(repository, scope: socket.assigns.current_scope))
     |> load_scans()}
  end

  @impl true
  def handle_info({:scan_submitted, scan}, socket) do
    {:noreply, sync_visible_scan(socket, scan, at: 0)}
  end

  def handle_info({:scan_updated, scan}, socket) do
    {:noreply, sync_visible_scan(socket, scan)}
  end

  def handle_info(
        {:repository_record_updated, %Repository{id: repository_id}},
        %{assigns: %{repository: %Repository{id: repository_id}}} = socket
      ) do
    {:noreply, refresh_visible_repository(socket)}
  end

  def handle_info({event, %Repository{}}, socket)
      when event in [:repository_registered, :repository_record_updated] do
    {:noreply, socket}
  end

  def handle_info({event, _task_id}, socket)
      when event in [
             :review_task_created,
             :review_task_updated,
             :review_task_published,
             :review_task_submitted,
             :review_task_accepted,
             :review_task_disclosed,
             :review_task_changes_requested,
             :review_task_rejected,
             :review_task_cancelled,
             :review_task_quarantined
           ] do
    {:noreply, reload_tasks(socket)}
  end

  def handle_info({:vote_changed, "canonical_finding", _id}, socket) do
    {:noreply, load_scans(socket)}
  end

  def handle_info({:vote_changed, _type, _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_task_form", _params, socket) do
    show = !socket.assigns.show_task_form

    socket =
      if show do
        socket
        |> assign(:show_task_form, true)
        |> load_branch_options()
        |> assign(:task_form, draft_task_form(socket.assigns.repository, %{}))
      else
        assign(socket, :show_task_form, false)
      end

    {:noreply, socket}
  end

  def handle_event("select_branch", %{"branch" => branch}, socket) do
    repository = socket.assigns.repository
    branch = String.trim(to_string(branch || ""))

    case RepositoryCode.resolve_branch_commit(repository, branch) do
      {:ok, commit_sha} ->
        params =
          (socket.assigns.task_form.params || %{})
          |> Map.put("commit_sha", commit_sha)

        # Clear title so it re-fills with the new short SHA.
        params = Map.put(params, "title", "")

        {:noreply,
         socket
         |> assign(:selected_branch, branch)
         |> assign(:task_form, draft_task_form(repository, params))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not resolve branch #{inspect(branch)} to a commit.")}
    end
  end

  # One-click mass path: default-branch HEAD, code_review, agent, auto title/description.
  # Stewards/moderators get an immediately open job; others get a proposal.
  def handle_event(
        "quick_open_job",
        _params,
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    repository = socket.assigns.repository

    params =
      case RepositoryCode.resolve_default_commit(repository) do
        {:ok, commit_sha} -> %{"commit_sha" => commit_sha}
        {:error, _} -> %{}
      end

    create_task_from_params(socket, params)
  end

  def handle_event("quick_open_job", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  def handle_event(
        "vote",
        %{"type" => subject_type, "id" => subject_id, "vote" => value},
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    case Reputation.cast_vote(
           socket.assigns.current_scope,
           subject_type,
           String.to_integer(subject_id),
           String.to_integer(value)
         ) do
      {:ok, _summary} ->
        {:noreply, load_scans(socket)}

      {:error, :own_content} ->
        {:noreply, put_flash(socket, :error, "You cannot vote on your own contribution.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Your vote could not be recorded.")}
    end
  end

  def handle_event("vote", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  # Fills the proposal form with the selected (or default) branch tip.
  def handle_event("use_default_commit", _params, socket) do
    repository = socket.assigns.repository
    branch = socket.assigns.selected_branch || repository.default_branch

    result =
      if is_binary(branch) and branch != "" do
        RepositoryCode.resolve_branch_commit(repository, branch)
      else
        RepositoryCode.resolve_default_commit(repository)
      end

    case result do
      {:ok, commit_sha} ->
        params =
          (socket.assigns.task_form.params || %{})
          |> Map.put("commit_sha", commit_sha)
          |> Map.put("title", "")

        {:noreply, assign(socket, :task_form, draft_task_form(repository, params))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The branch tip could not be resolved to a commit.")}
    end
  end

  def handle_event("validate_task", %{"review_task" => params}, socket) do
    params = normalize_task_params(params)
    form = draft_task_form(socket.assigns.repository, params, action: :validate)
    {:noreply, assign(socket, :task_form, form)}
  end

  def handle_event(
        "create_task",
        %{"review_task" => params},
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    create_task_from_params(socket, normalize_task_params(params))
  end

  def handle_event("create_task", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  def handle_event(
        "cancel_task",
        %{"id" => id},
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    task =
      Work.list_tasks(socket.assigns.repository, scope: socket.assigns.current_scope)
      |> Enum.find(&(to_string(&1.id) == to_string(id)))

    case task do
      nil ->
        {:noreply, put_flash(socket, :error, "Job not found.")}

      task ->
        case Work.cancel_task(task, socket.assigns.current_scope, %{
               "reason" => "Cancelled from the repository security page by a steward or creator."
             }) do
          {:ok, _cancelled} ->
            {:noreply,
             socket
             |> reload_tasks()
             |> put_flash(:info, "Job cancelled.")}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You cannot cancel this job.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not cancel this job.")}
        end
    end
  end

  def handle_event("cancel_task", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  def handle_event(
        "record_finding_verdict",
        %{
          "finding_id" => public_id,
          "commit_sha" => commit_sha,
          "verdict" => verdict,
          "notes" => notes
        },
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    attrs = %{
      "commit_sha" => commit_sha,
      "verdict" => verdict,
      "provenance" => "human",
      "notes" => notes
    }

    case FindingMemory.record_check(
           socket.assigns.current_scope,
           socket.assigns.repository,
           public_id,
           attrs
         ) do
      {:ok, _check, _canonical} ->
        {:noreply,
         socket
         |> reload_repository()
         |> load_scans()
         |> put_flash(:info, "Finding check recorded.")}

      {:error, :conflict_of_interest} ->
        {:noreply, put_flash(socket, :error, "You cannot verify a finding you submitted.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to verify this finding.")}

      {:error, %Ecto.Changeset{errors: [{_field, {message, _meta}} | _]}} ->
        {:noreply, put_flash(socket, :error, "Finding check not recorded: #{message}.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Finding check could not be recorded.")}
    end
  end

  def handle_event("record_finding_verdict", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  def handle_event(
        "moderate_scan",
        %{"scan_id" => scan_id, "decision" => decision, "moderation" => attrs},
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    with_recent_auth(socket, fn ->
      with {:ok, scan} <- Scans.get_scan(socket.assigns.current_scope, scan_id) do
        result =
          case decision do
            "accept" ->
              Scans.accept_scan(socket.assigns.current_scope, scan, attrs)

            "reject" ->
              Scans.reject_scan(socket.assigns.current_scope, scan, attrs)

            "contest" ->
              Scans.contest_scan(socket.assigns.current_scope, scan, attrs)

            "publish_summary" ->
              Scans.update_visibility(socket.assigns.current_scope, scan, "public_summary", attrs)

            "publish_full" ->
              Scans.update_visibility(socket.assigns.current_scope, scan, "public", attrs)

            "restrict" ->
              Scans.update_visibility(socket.assigns.current_scope, scan, "restricted", attrs)

            _other ->
              {:error, :invalid_transition}
          end

        case result do
          {:ok, updated_scan} ->
            {:noreply,
             socket
             |> assign(:moderation_form, moderation_form())
             |> sync_visible_scan(updated_scan)
             |> put_flash(:info, "Review decision recorded.")}

          {:error, :verification_required} ->
            {:noreply, put_flash(socket, :error, "Acceptance requires verification quorum.")}

          {:error, reason} when reason in [:unauthorized, :conflict_of_interest] ->
            {:noreply, put_flash(socket, :error, "You cannot moderate this review.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:moderation_form, to_form(changeset, as: :moderation))
             |> put_flash(:error, "Decision needs a reason and evidence.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Review decision could not be recorded.")}
        end
      else
        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Review is unavailable.")}
      end
    end)
  end

  def handle_event("moderate_scan", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  defp reload_repository(socket) do
    %{host: host, owner: owner, name: name} = socket.assigns.repository
    assign(socket, :repository, Repositories.get_repository(host, owner, name))
  end

  defp refresh_visible_repository(socket) do
    %{host: host, owner: owner, name: name} = socket.assigns.repository

    case Repositories.get_visible_repository(host, owner, name, socket.assigns.current_scope) do
      nil ->
        push_navigate(socket, to: ~p"/")

      repository ->
        scans = Scans.list_scans(socket.assigns.current_scope, repository)

        socket
        |> assign(:repository, repository)
        |> assign(
          :canonical_findings,
          canonical_findings(
            repository,
            socket.assigns.current_scope,
            current_account_id(socket)
          )
        )
        |> stream(:tasks, Work.list_tasks(repository, scope: socket.assigns.current_scope),
          reset: true
        )
        |> assign(:task_target_options, task_target_options(scans))
        |> stream(:scans, scans, reset: true)
    end
  end

  defp reload_tasks(socket) do
    tasks = Work.list_tasks(socket.assigns.repository, scope: socket.assigns.current_scope)
    stream(socket, :tasks, tasks, reset: true)
  end

  # Raw reports are immutable provenance. Shared votes and checks are loaded
  # once for each canonical issue instead of being repeated on occurrences.
  defp load_scans(socket) do
    scans = Scans.list_scans(socket.assigns.current_scope, socket.assigns.repository)

    socket
    |> assign(
      :canonical_findings,
      canonical_findings(
        socket.assigns.repository,
        socket.assigns.current_scope,
        current_account_id(socket)
      )
    )
    |> assign(:task_target_options, task_target_options(scans))
    |> stream(:scans, scans, reset: true)
  end

  defp canonical_findings(repository, scope, account_id) do
    findings = FindingMemory.list_repository_memory(repository, limit: 200)

    votes =
      Reputation.vote_summaries("canonical_finding", Enum.map(findings, & &1.id), account_id)

    checkable_ids = FindingMemory.checkable_public_ids(scope, repository, findings)

    findings
    |> Enum.map(fn finding ->
      Map.merge(finding, %{
        can_check: MapSet.member?(checkable_ids, finding.public_id),
        vote_summary: Map.get(votes, finding.id, %{score: 0, my_vote: 0})
      })
    end)
  end

  defp current_account_id(%{assigns: %{current_scope: %{account: %{id: id}}}}), do: id
  defp current_account_id(_socket), do: nil

  defp can_vote?(socket), do: not is_nil(current_account_id(socket))

  defp create_task_from_params(socket, params) do
    params = normalize_task_params(params)

    case Work.create_task(socket.assigns.repository, socket.assigns.current_scope, params) do
      {:ok, task} ->
        message =
          if task.status == "open" do
            "Job opened on the public queue."
          else
            "Job proposed for independent approval."
          end

        {:noreply,
         socket
         |> assign(:task_form, empty_task_form(socket.assigns.repository))
         |> assign(:show_task_form, false)
         |> stream_insert(:tasks, task, at: 0)
         |> put_flash(:info, message)}

      {:error, :commit_not_found} ->
        {:noreply, assign_task_error(socket, params, :commit_sha, "commit was not found")}

      {:error, :commit_mismatch} ->
        {:noreply,
         assign_task_error(socket, params, :commit_sha, "commit verification returned a mismatch")}

      {:error, reason} when reason in [:rate_limited, :unavailable] ->
        {:noreply,
         assign_task_error(socket, params, :commit_sha, "commit could not be verified right now")}

      {:error, reason} when reason in [:identity_changed, :not_public] ->
        {:noreply,
         assign_task_error(
           socket,
           params,
           :commit_sha,
           "repository identity is no longer confirmed public (GitHub-backed repos only - Tarakan-hosted repos use the local git object database)"
         )}

      {:error, :proposal_limit} ->
        {:noreply, put_flash(socket, :error, "Daily review-task proposal limit reached.")}

      {:error, :proposal_rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many task proposals. Try again shortly.")}

      {:error, :duplicate_job} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "An open job already covers this commit and job type. Claim or complete that one first."
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "This account cannot propose jobs.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:show_task_form, true)
         |> assign(:task_form, to_form(changeset, as: :review_task))}
    end
  end

  defp assign_task_error(socket, params, field, message) do
    filled = Work.fill_task_defaults(socket.assigns.repository, params)

    form =
      %ReviewTask{}
      |> Work.change_task(filled)
      |> Ecto.Changeset.add_error(field, message)
      |> Map.put(:action, :validate)
      |> to_form(as: :review_task)

    socket
    |> assign(:show_task_form, true)
    |> assign(:task_form, form)
  end

  defp empty_task_form(repository) do
    draft_task_form(repository, %{})
  end

  defp draft_task_form(repository, params, opts \\ []) do
    params =
      params
      |> maybe_default_commit(repository)
      |> then(&Work.fill_task_defaults(repository, &1))

    changeset =
      %ReviewTask{}
      |> Work.change_task(params)

    changeset =
      case Keyword.get(opts, :action) do
        nil -> changeset
        action -> Map.put(changeset, :action, action)
      end

    to_form(changeset, as: :review_task)
  end

  defp load_branch_options(socket) do
    repository = socket.assigns.repository

    case RepositoryCode.list_branches(repository) do
      {:ok, branches} ->
        default = repository.default_branch
        selected = socket.assigns[:selected_branch] || default || List.first(branches)

        socket
        |> assign(:branch_options, branches)
        |> assign(:selected_branch, selected)

      {:error, _} ->
        default = repository.default_branch

        branches =
          if is_binary(default) and default != "", do: [default], else: []

        socket
        |> assign(:branch_options, branches)
        |> assign(:selected_branch, default)
    end
  end

  defp maybe_default_commit(params, repository) do
    params = for {k, v} <- params, into: %{}, do: {to_string(k), v}

    if present_param?(params["commit_sha"]) do
      params
    else
      case RepositoryCode.resolve_default_commit(repository) do
        {:ok, commit_sha} -> Map.put(params, "commit_sha", commit_sha)
        {:error, _} -> params
      end
    end
  end

  defp present_param?(value) when value in [nil, ""], do: false
  defp present_param?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_param?(_), do: true

  defp can_auto_open_job?(%{assigns: %{current_scope: scope}}, repository)
       when not is_nil(scope) do
    # publish_task is checked against the repository for stewards; moderators always can.
    Policy.allowed?(scope, :publish_task, repository) or
      Policy.allowed?(scope, :manage_repository, repository)
  end

  defp can_auto_open_job?(_socket, _repository), do: false

  defp can_cancel_job?(task, %{account: %{id: account_id}} = scope) when not is_nil(account_id) do
    task.status in ["proposed", "open", "claimed", "changes_requested"] and
      Policy.allowed?(scope, :cancel_task, task)
  end

  defp can_cancel_job?(_task, _scope), do: false

  defp can_moderate?(scan, %{account: account} = scope) when not is_nil(account) do
    Policy.allowed?(scope, :moderate_review, scan) and scan.submitted_by_id != account.id
  end

  defp can_moderate?(_scan, _scope), do: false

  defp moderation_form do
    to_form(
      %{
        "visibility" => "restricted",
        "moderation_reason" => "",
        "moderation_notes" => ""
      },
      as: :moderation
    )
  end

  defp with_recent_auth(socket, fun) do
    if Accounts.sudo_mode?(socket.assigns.current_scope.account) do
      fun.()
    else
      repo = socket.assigns.repository
      return_to = TarakanWeb.RepositoryPaths.repository_path(repo)

      {:noreply,
       socket
       |> put_flash(
         :error,
         "Confirm it's you with a magic link before changing review disclosure (sign-in older than 8 hours)."
       )
       |> push_navigate(to: TarakanWeb.AccountAuth.reauth_path(return_to))}
    end
  end

  defp sync_visible_scan(socket, scan, opts \\ []) do
    socket = reload_repository(socket)

    socket =
      case Scans.get_scan(socket.assigns.current_scope, scan.id) do
        {:ok, visible_scan} -> stream_insert(socket, :scans, visible_scan, opts)
        {:error, :not_found} -> stream_delete(socket, :scans, scan)
      end

    scans = Scans.list_scans(socket.assigns.current_scope, socket.assigns.repository)
    assign(socket, :task_target_options, task_target_options(scans))
  end

  defp short_sha(sha), do: String.slice(sha, 0, 7)

  defp scan_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  # Signal is reserved for findings; quiet states stay quiet.

  defp finding_lines(%{line_start: nil}), do: ""
  defp finding_lines(%{line_start: line, line_end: line}), do: ":#{line}"

  defp finding_lines(%{line_start: line_start, line_end: line_end}),
    do: ":#{line_start}-#{line_end}"

  defp repository_meta_description(repository) do
    label = TarakanWeb.RepositoryComponents.repository_status_label(repository)
    host = repository.host || "github.com"

    base =
      "Public security record for #{repository.owner}/#{repository.name} on #{host}. " <>
        "#{label}."

    detail =
      cond do
        (repository.open_findings_count || 0) > 0 ->
          " See open findings and open jobs."

        true ->
          " Contribute a review or claim an open job."
      end

    String.slice(base <> detail, 0, 160)
  end

  # Mass UI: Report job + Check job first; advanced kinds still available.
  defp task_kind_options do
    primary = [
      {"Security report (findings)", "code_review"},
      {"Check an existing report", "verify_findings"}
    ]

    advanced =
      ~w(threat_model privacy_review business_logic write_fix)
      |> Enum.map(&{review_kind_label(&1) <> " (advanced)", &1})

    primary ++ advanced
  end

  defp task_target_options(scans) do
    scans
    |> Enum.filter(&(&1.findings_count > 0))
    |> Enum.map(fn scan ->
      count_label =
        if scan.findings_count == 1, do: "1 finding", else: "#{scan.findings_count} findings"

      {
        "Report ##{scan.id} · #{review_kind_label(scan.review_kind)} · #{short_sha(scan.commit_sha)} · #{count_label}",
        scan.id
      }
    end)
  end

  defp normalize_task_params(%{"kind" => "verify_findings"} = params), do: params
  defp normalize_task_params(params), do: Map.delete(params, "target_review_id")

  defp capability_options do
    [
      {"Me (human)", "human"},
      {"AI helper (agent)", "agent"},
      {"Me + AI (hybrid)", "hybrid"}
    ]
  end

  defp short_task_status(%{status: "claimed"} = task) do
    if Tarakan.Work.ReviewTask.claim_active?(task), do: "Claimed", else: "Open"
  end

  defp short_task_status(%{status: "changes_requested"}), do: "Changes requested"

  defp short_task_status(%{status: status}), do: String.capitalize(status)

  defp empty_review_label(%{review_kind: "code_review"}), do: "No findings reported"
  defp empty_review_label(_scan), do: "Reviewed"
end
