defmodule TarakanWeb.ModerationQueueLive.Index do
  use TarakanWeb, :live_view

  alias Tarakan.Moderation

  @impl true
  def mount(_params, _session, socket) do
    case Moderation.list_open(socket.assigns.current_scope) do
      {:ok, cases} ->
        {:ok,
         socket
         |> assign(:page_title, "Moderation queue")
         |> assign(:case_count, length(cases))
         |> stream(:cases, cases)}

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, "Moderator access is required.")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("assign", %{"id" => id}, socket) do
    with {:ok, case_record} <- Moderation.get_case(socket.assigns.current_scope, id),
         {:ok, _assigned} <- Moderation.assign(socket.assigns.current_scope, case_record) do
      {:noreply,
       socket
       |> refresh_queue()
       |> put_flash(:info, "Case assigned for independent review.")}
    else
      error -> {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("assign", _params, socket) do
    {:noreply, put_flash(socket, :error, "That case is no longer available.")}
  end

  defp refresh_queue(socket) do
    case Moderation.list_open(socket.assigns.current_scope) do
      {:ok, cases} ->
        socket
        |> assign(:case_count, length(cases))
        |> stream(:cases, cases, reset: true)

      {:error, :unauthorized} ->
        socket
        |> put_flash(:error, "Moderator access is required.")
        |> push_navigate(to: ~p"/")
    end
  end

  defp can_assign?(case_record, scope) do
    independent = scope.account_id not in [case_record.reporter_id, case_record.subject_owner_id]

    independent and
      (case_record.status == "open" or
         (case_record.status == "in_review" and scope.platform_role == "admin"))
  end

  defp status_label("in_review"), do: "In review"
  defp status_label(status), do: String.capitalize(status)

  defp subject_label("review_task"), do: "Job"

  defp subject_label(subject_type),
    do: subject_type |> String.replace("_", " ") |> String.capitalize()

  defp reason_label(reason), do: reason |> String.replace("_", " ") |> String.capitalize()

  defp error_message({:error, :conflict_of_interest}),
    do: "An independent moderator must handle that case."

  defp error_message({:error, :unauthorized}), do: "Moderator access is required."
  defp error_message({:error, :not_found}), do: "That case is no longer available."
  defp error_message({:error, _reason}), do: "The case could not be assigned."
end
