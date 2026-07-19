defmodule TarakanWeb.ModerationCaseLive.Show do
  use TarakanWeb, :live_view

  alias Tarakan.Accounts
  alias Tarakan.Moderation
  alias Tarakan.Policy

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Moderation.get_case(socket.assigns.current_scope, id) do
      {:ok, case_record} ->
        {:ok,
         socket
         |> assign(:page_title, "Moderation case ##{case_record.id}")
         |> assign(:appeal_form, appeal_form())
         |> assign(:resolution_form, resolution_form())
         |> assign_case(case_record)}

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: Tarakan.Moderation.Case
    end
  end

  @impl true
  def handle_event("assign", _params, socket) do
    case Moderation.assign(
           socket.assigns.current_scope,
           socket.assigns.case_record
         ) do
      {:ok, case_record} ->
        {:noreply,
         socket
         |> assign_case(case_record)
         |> put_flash(:info, "Case assigned for independent review.")}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(
        "resolve",
        %{"disposition" => disposition, "resolution" => %{"reason" => reason}},
        socket
      )
      when disposition in ["resolved", "dismissed"] do
    with_recent_auth(socket, fn ->
      case Moderation.resolve(
             socket.assigns.current_scope,
             socket.assigns.case_record,
             disposition,
             reason
           ) do
        {:ok, case_record} ->
          {:noreply,
           socket
           |> assign(:resolution_form, resolution_form())
           |> assign_case(case_record)
           |> put_flash(:info, resolution_message(disposition))}

        error ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    end)
  end

  def handle_event("resolve", _params, socket) do
    {:noreply, put_flash(socket, :error, "Choose a valid moderation outcome.")}
  end

  def handle_event("appeal", %{"appeal" => attrs}, socket) do
    case Moderation.appeal(
           socket.assigns.current_scope,
           socket.assigns.case_record,
           attrs
         ) do
      {:ok, _appeal} ->
        {:noreply,
         socket
         |> refresh_case()
         |> put_flash(:info, "Appeal submitted for independent review.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :appeal_form, to_form(changeset, as: :appeal))}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("appeal", _params, socket) do
    {:noreply, put_flash(socket, :error, "The appeal is incomplete.")}
  end

  def handle_event(
        "decide_appeal",
        %{
          "decision" => decision,
          "appeal_decision" => %{"appeal_id" => appeal_id, "reason" => reason}
        },
        socket
      )
      when decision in ["upheld", "denied"] do
    with_recent_auth(socket, fn ->
      with {:ok, appeal_id} <- normalize_id(appeal_id),
           appeal when not is_nil(appeal) <-
             Enum.find(socket.assigns.case_record.appeals, &(&1.id == appeal_id)) do
        case Moderation.decide_appeal(
               socket.assigns.current_scope,
               appeal,
               decision,
               reason
             ) do
          {:ok, _appeal} ->
            {:noreply,
             socket
             |> refresh_case()
             |> put_flash(:info, appeal_decision_message(decision))}

          error ->
            {:noreply, put_flash(socket, :error, error_message(error))}
        end
      else
        _other -> {:noreply, put_flash(socket, :error, "That appeal is no longer available.")}
      end
    end)
  end

  def handle_event("decide_appeal", _params, socket) do
    {:noreply, put_flash(socket, :error, "Choose a valid appeal decision.")}
  end

  defp refresh_case(socket) do
    case Moderation.get_case(socket.assigns.current_scope, socket.assigns.case_record.id) do
      {:ok, case_record} -> assign_case(socket, case_record)
      {:error, :not_found} -> push_navigate(socket, to: ~p"/")
    end
  end

  defp assign_case(socket, case_record) do
    socket
    |> assign(:case_record, case_record)
    |> assign(:moderator?, moderator?(socket.assigns.current_scope))
    |> assign(
      :appeal_decision_forms,
      Map.new(case_record.appeals, &{&1.id, appeal_decision_form(&1)})
    )
  end

  defp moderator?(scope), do: Policy.moderator?(scope) and scope.account_state == "active"

  defp can_assign?(case_record, scope) do
    moderator?(scope) and independent_from_case?(case_record, scope) and
      (case_record.status == "open" or
         (case_record.status == "in_review" and scope.platform_role == "admin"))
  end

  defp can_resolve?(case_record, scope) do
    moderator?(scope) and case_record.status == "in_review" and
      case_record.assigned_to_id == scope.account_id
  end

  defp can_appeal?(case_record, scope) do
    case_record.status == "resolved" and case_record.appeals == [] and
      (case_record.subject_owner_id == scope.account_id or
         Policy.repository_steward?(scope, case_record))
  end

  defp can_decide_appeal?(case_record, appeal, scope) do
    moderator?(scope) and appeal.status == "open" and
      scope.account_id not in [
        case_record.reporter_id,
        case_record.subject_owner_id,
        case_record.resolved_by_id,
        appeal.appellant_id
      ]
  end

  defp independent_from_case?(case_record, scope) do
    scope.account_id not in [case_record.reporter_id, case_record.subject_owner_id]
  end

  defp appeal_form, do: to_form(%{"reason" => ""}, as: :appeal)
  defp resolution_form, do: to_form(%{"reason" => ""}, as: :resolution)

  defp with_recent_auth(socket, fun) do
    if Accounts.sudo_mode?(socket.assigns.current_scope.account) do
      fun.()
    else
      return_to = ~p"/moderation/cases/#{socket.assigns.case.id}"

      {:noreply,
       socket
       |> put_flash(
         :error,
         "Confirm it's you with a magic link before deciding moderation outcomes (sign-in older than 8 hours)."
       )
       |> push_navigate(to: TarakanWeb.AccountAuth.reauth_path(return_to))}
    end
  end

  defp appeal_decision_form(appeal) do
    to_form(%{"appeal_id" => appeal.id, "reason" => ""}, as: :appeal_decision)
  end

  defp normalize_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, :invalid_id}
    end
  end

  defp normalize_id(_id), do: {:error, :invalid_id}

  defp status_label("in_review"), do: "In review"
  defp status_label(status), do: String.capitalize(status)

  defp subject_label("review_task"), do: "Job"

  defp subject_label(subject_type),
    do: subject_type |> String.replace("_", " ") |> String.capitalize()

  defp reason_label(reason), do: reason |> String.replace("_", " ") |> String.capitalize()

  defp resolution_message("resolved"), do: "Case resolved."
  defp resolution_message("dismissed"), do: "Case dismissed."

  defp appeal_decision_message("upheld"), do: "Appeal upheld and case overturned."
  defp appeal_decision_message("denied"), do: "Appeal denied."

  defp error_message({:error, :conflict_of_interest}),
    do: "An independent moderator must handle this action."

  defp error_message({:error, :not_assigned}), do: "This case is assigned to another moderator."
  defp error_message({:error, :not_appealable}), do: "This case is not eligible for appeal."
  defp error_message({:error, :already_decided}), do: "That appeal has already been decided."
  defp error_message({:error, :invalid_reason}), do: "Provide a reason of at least 10 characters."

  defp error_message({:error, :invalid_transition}),
    do: "That case transition is no longer valid."

  defp error_message({:error, :unauthorized}), do: "You are not authorized for that action."
  defp error_message({:error, :not_found}), do: "The case is no longer available."
  defp error_message({:error, _reason}), do: "The moderation action could not be completed."
end
