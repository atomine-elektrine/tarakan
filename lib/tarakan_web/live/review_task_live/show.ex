defmodule TarakanWeb.ReviewTaskLive.Show do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts
  alias Tarakan.Policy
  alias Tarakan.Scans
  alias Tarakan.Work
  alias Tarakan.Work.{Contribution, ReviewTask}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    task =
      Work.get_visible_task(id, socket.assigns.current_scope) ||
        raise Ecto.NoResultsError, queryable: ReviewTask

    if connected?(socket), do: Work.subscribe(task.repository_id)

    {:ok,
     socket
     |> assign(:page_title, task.title)
     |> assign(:meta_description, task_meta_description(task))
     |> assign(:canonical_path, ~p"/requests/#{task.id}")
     |> assign_task(task)
     |> assign(:decision_form, decision_form(task))
     |> assign(:disclosure_form, disclosure_form())}
  end

  @impl true
  def handle_info({event, task_id}, %{assigns: %{task: current_task}} = socket)
      when event in [
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
    if task_id == current_task.id do
      case Work.get_visible_task(task_id, socket.assigns.current_scope) do
        nil -> {:noreply, push_navigate(socket, to: repository_path(current_task))}
        task -> {:noreply, assign_task(socket, task)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("claim", _params, %{assigns: %{current_scope: scope, task: task}} = socket) do
    respond(socket, Work.claim_task(task, scope), "Task claimed.")
  end

  def handle_event("release", _params, %{assigns: %{current_scope: scope, task: task}} = socket) do
    respond(socket, Work.release_task(task, scope), "Claim released.")
  end

  def handle_event("validate_contribution", %{"contribution" => params}, socket) do
    form =
      %Contribution{}
      |> Work.change_contribution(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :contribution)

    {:noreply, assign(socket, :contribution_form, form)}
  end

  def handle_event(
        "complete",
        %{"contribution" => params},
        %{assigns: %{current_scope: scope, task: task}} = socket
      ) do
    case Work.submit_task(task, scope, params) do
      {:ok, task} ->
        {:noreply,
         socket
         |> assign_task(task)
         |> put_flash(:info, "Evidence submitted for independent review.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :contribution_form, to_form(changeset, as: :contribution))}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(
        "complete_verification",
        %{"verification" => params},
        %{assigns: %{current_scope: scope, task: task}} = socket
      ) do
    case Work.submit_task(task, scope, params) do
      {:ok, task} ->
        {:noreply,
         socket
         |> assign_task(task)
         |> put_flash(:info, "Finding verdict and evidence submitted for independent review.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:verification_form, verification_form(task, params))
         |> put_flash(:error, changeset_error(changeset))}

      error ->
        {:noreply,
         socket
         |> assign(:verification_form, verification_form(task, params))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event(
        "publish",
        %{"decision" => params},
        %{assigns: %{current_scope: scope, task: task}} = socket
      ) do
    with_recent_auth(socket, fn ->
      respond(
        socket,
        Work.publish_task(task, scope, params),
        "Task approved for the public queue."
      )
    end)
  end

  def handle_event(
        "review",
        %{"action" => action, "decision" => params},
        %{assigns: %{current_scope: scope, task: task}} = socket
      )
      when action in ["accept", "request_changes", "reject"] do
    with_recent_auth(socket, fn ->
      {result, message} =
        case action do
          "accept" ->
            {Work.accept_task(task, scope, params),
             "Contribution accepted and held for a separate disclosure decision."}

          "request_changes" ->
            {Work.request_changes(task, scope, params), "Changes requested."}

          "reject" ->
            {Work.reject_task(task, scope, params), "Contribution rejected."}
        end

      respond(socket, result, message)
    end)
  end

  def handle_event("review", _params, socket) do
    {:noreply, put_flash(socket, :error, "The requested review action is invalid.")}
  end

  def handle_event(
        "disclose",
        %{"visibility" => visibility, "disclosure" => params},
        %{assigns: %{current_scope: scope, task: task}} = socket
      )
      when visibility in ["public_summary", "public"] do
    with_recent_auth(socket, fn ->
      message =
        if visibility == "public",
          do: "Full evidence disclosed after sensitive-data review.",
          else: "A redacted result summary is now public."

      respond_disclosure(
        socket,
        Work.disclose_task(task, scope, visibility, params),
        message,
        params
      )
    end)
  end

  def handle_event("disclose", _params, socket) do
    {:noreply, put_flash(socket, :error, "The requested disclosure is invalid.")}
  end

  def handle_event(
        "cancel",
        %{"decision" => params},
        %{assigns: %{current_scope: scope, task: task}} = socket
      ) do
    respond(socket, Work.cancel_task(task, scope, params), "Task cancelled.")
  end

  defp respond(socket, {:ok, task}, message) do
    {:noreply, socket |> assign_task(task) |> put_flash(:info, message)}
  end

  defp respond(socket, {:error, %Ecto.Changeset{} = changeset}, _message) do
    {:noreply, assign(socket, :decision_form, to_form(changeset, as: :decision))}
  end

  defp respond(socket, error, _message) do
    {:noreply, put_flash(socket, :error, error_message(error))}
  end

  defp respond_disclosure(socket, {:ok, task}, message, _params) do
    {:noreply,
     socket
     |> assign_task(task)
     |> assign(:disclosure_form, disclosure_form())
     |> put_flash(:info, message)}
  end

  defp respond_disclosure(
         socket,
         {:error, %Ecto.Changeset{} = changeset},
         _message,
         params
       ) do
    form =
      params
      |> Map.take(["reason", "sensitive_data_reviewed"])
      |> to_form(as: :disclosure, errors: changeset.errors)

    {:noreply, assign(socket, :disclosure_form, form)}
  end

  defp respond_disclosure(socket, error, _message, _params) do
    {:noreply, put_flash(socket, :error, error_message(error))}
  end

  defp assign_task(socket, task) do
    socket
    |> assign(:task, task)
    |> assign(:visible_target_review, visible_target_review(socket.assigns.current_scope, task))
    |> assign(:provenance_options, provenance_options(task))
    |> assign(:verification_form, verification_form(task))
    |> assign(:decision_form, decision_form(task))
    |> assign(
      :contribution_form,
      to_form(
        Work.change_contribution(%Contribution{}, %{
          "provenance" => task |> allowed_provenances() |> List.first()
        }),
        as: :contribution
      )
    )
  end

  defp decision_form(%ReviewTask{status: "proposed"} = task) do
    to_form(%{"reason" => Work.default_publish_reason(task), "evidence" => ""}, as: :decision)
  end

  defp decision_form(_task) do
    to_form(%{"reason" => "", "evidence" => ""}, as: :decision)
  end

  defp disclosure_form do
    to_form(
      %{"reason" => "", "sensitive_data_reviewed" => "false"},
      as: :disclosure
    )
  end

  defp verification_form(task, params \\ %{}) do
    defaults = %{
      "provenance" => task |> allowed_provenances() |> List.first(),
      "verdict" => "confirmed",
      "notes" => "",
      "evidence" => ""
    }

    defaults
    |> Map.merge(params)
    |> to_form(as: :verification)
  end

  defp visible_target_review(_scope, %{target_review_id: nil}), do: nil

  defp visible_target_review(scope, %{target_review_id: review_id}) do
    case Scans.get_scan(scope, review_id) do
      {:ok, review} -> review
      {:error, :not_found} -> nil
    end
  end

  defp changeset_error(%Ecto.Changeset{errors: [{_field, {message, _opts}} | _]}),
    do: "Verification was not submitted: #{message}."

  defp changeset_error(_changeset), do: "Verification was not submitted."

  defp with_recent_auth(socket, fun) do
    account = socket.assigns.current_scope && socket.assigns.current_scope.account

    if account && Accounts.sudo_mode?(account) do
      fun.()
    else
      return_to = ~p"/work/#{socket.assigns.task.id}"

      {:noreply,
       socket
       |> put_flash(
         :error,
         "Confirm it's you with a magic link before changing the public record (sign-in older than 8 hours)."
       )
       |> push_navigate(to: TarakanWeb.AccountAuth.reauth_path(return_to))}
    end
  end

  defp owns_claim?(task, %{account_id: account_id}) when is_integer(account_id) do
    task.claimed_by_id == account_id and ReviewTask.claim_active?(task)
  end

  defp owns_claim?(_task, _scope), do: false

  defp can_claim?(task, scope) do
    claimable_for_display?(task) and Policy.allowed?(scope, :claim_task, task)
  end

  defp can_publish?(%{status: "proposed"} = task, %{account_id: account_id} = scope)
       when is_integer(account_id) do
    # Stewards/owners and moderators may publish, including their own proposals.
    Policy.allowed?(scope, :publish_task, task)
  end

  defp can_publish?(_task, _scope), do: false

  defp can_review?(%{status: "submitted"} = task, %{account_id: account_id} = scope)
       when is_integer(account_id) do
    task.created_by_id != account_id and task.claimed_by_id != account_id and
      not Enum.any?(task.contributions, &(&1.account_id == account_id)) and
      Policy.allowed?(scope, :review_contribution, task)
  end

  defp can_review?(_task, _scope), do: false

  defp can_disclose?(%{status: "accepted"} = task, scope) do
    Policy.allowed?(scope, :disclose_task, task)
  end

  defp can_disclose?(_task, _scope), do: false

  defp full_disclosure_allowed?(task) do
    task.repository.participation_mode in ["maintainer_verified", "curated"]
  end

  defp can_cancel?(task, scope) do
    task.status in ["proposed", "open", "changes_requested"] and
      Policy.allowed?(scope, :cancel_task, task)
  end

  defp created_by_current_account?(task, %{account_id: account_id})
       when is_integer(account_id),
       do: task.created_by_id == account_id

  defp created_by_current_account?(_task, _scope), do: false

  defp claimable_for_display?(%{status: "claimed"} = task),
    do: not ReviewTask.claim_active?(task)

  defp claimable_for_display?(task), do: ReviewTask.claimable?(task)

  defp error_message({:error, :own_task}), do: "That action is not allowed on this job."
  defp error_message({:error, :not_independent}), do: "An independent reviewer is required."
  defp error_message({:error, :already_claimed}), do: "This task is already claimed."
  defp error_message({:error, :claim_limit}), do: "You have reached your active claim limit."
  defp error_message({:error, :claim_expired}), do: "Your claim expired. Claim the task again."

  defp error_message({:error, :capability_mismatch}),
    do: "The provenance does not match the task."

  defp error_message({:error, :verdict_required}),
    do: "Choose confirmed or disputed and provide verification notes."

  defp error_message({:error, :target_review_required}),
    do: "This check job has no target report."

  defp error_message({:error, :target_review_mismatch}),
    do: "The selected report does not match this check job."

  defp error_message({:error, :not_claimant}), do: "You do not hold this claim."
  defp error_message({:error, :closed}), do: "This task is closed."
  defp error_message({:error, :not_open}), do: "This task is not open for claims."
  defp error_message({:error, :invalid_state}), do: "That transition is no longer valid."
  defp error_message({:error, :active_work}), do: "Resolve active work before cancelling."
  defp error_message({:error, :invalid_visibility}), do: "That disclosure level is invalid."

  defp error_message({:error, :full_disclosure_not_allowed}),
    do: "Full evidence requires a maintainer-verified or curated repository."

  defp error_message({:error, :sensitive_data_review_required}),
    do: "Confirm that the evidence was checked for secrets and personal data."

  defp error_message({:error, :identity_changed}),
    do: "The repository is no longer confirmed public, so this result cannot be disclosed."

  defp error_message({:error, :claim_rate_limited}),
    do: "Too many claim changes. Wait a minute and try again."

  defp error_message({:error, :unauthorized}), do: "You are not authorized for that action."
  defp error_message({:error, _reason}), do: "The action could not be completed."

  defp task_meta_description(task) do
    repo =
      case task.repository do
        %{owner: owner, name: name} -> "#{owner}/#{name}"
        _ -> "open source"
      end

    kind = task.kind |> to_string() |> String.replace("_", " ")
    status = task.status |> to_string() |> String.replace("_", " ")

    desc =
      "Open security job on #{repo}: #{task.title}. " <>
        "#{String.capitalize(kind)} · #{status}. Claim on Tarakan."

    String.slice(String.replace(desc, ~r/\s+/, " "), 0, 160)
  end

  defp kind_label("code_review"), do: "Code review"
  defp kind_label("threat_model"), do: "Threat model"
  defp kind_label("privacy_review"), do: "Privacy review"
  defp kind_label("business_logic"), do: "Business logic"
  defp kind_label("verify_findings"), do: "Verify findings"
  defp kind_label("write_fix"), do: "Write a fix"

  defp provenance_options(task) do
    Enum.map(allowed_provenances(task), &{provenance_label(&1), &1})
  end

  defp agent_primary_path?(%{capability: "agent"}), do: true
  defp agent_primary_path?(_task), do: false

  defp allowed_provenances(%{capability: "human"}), do: ["human", "hybrid"]
  defp allowed_provenances(%{capability: "agent"}), do: ["agent", "hybrid"]
  defp allowed_provenances(%{capability: "hybrid"}), do: ["hybrid"]

  defp short_sha(sha), do: String.slice(sha, 0, 7)

  defp task_status(%{status: "claimed"} = task) do
    if ReviewTask.claim_active?(task), do: "Claimed", else: "Open"
  end

  defp task_status(%{status: "changes_requested"}), do: "Changes requested"
  defp task_status(%{status: status}), do: String.capitalize(status)

  defp visibility_label("restricted"), do: "Restricted"
  defp visibility_label("public_summary"), do: "Public summary"
  defp visibility_label("public"), do: "Full evidence public"

  defp repository_path(task),
    do: TarakanWeb.RepositoryPaths.repository_path(task.repository)
end
