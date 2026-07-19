defmodule TarakanWeb.ModerationReportLive.New do
  use TarakanWeb, :live_view

  alias Tarakan.Moderation

  @subject_options [
    {"Repository", "repository"},
    {"Account", "account"},
    {"Scan", "scan"},
    {"Finding", "finding"},
    {"Job", "review_task"},
    {"Contribution", "contribution"}
  ]

  @reason_options [
    {"Spam", "spam"},
    {"Unsafe disclosure", "unsafe_disclosure"},
    {"Harassment", "harassment"},
    {"Plagiarism", "plagiarism"},
    {"Malicious instructions", "malicious_instructions"},
    {"Fabricated evidence", "fabricated_evidence"},
    {"Secrets or personal data", "secrets_or_pii"},
    {"Other", "other"}
  ]

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Report content")
     |> assign(:subject_options, @subject_options)
     |> assign(:reason_options, @reason_options)
     |> assign(:form, report_form(initial_params(params)))}
  end

  @impl true
  def handle_event("submit", %{"report" => attrs}, socket) do
    case Moderation.report(socket.assigns.current_scope, attrs) do
      {:ok, case_record} ->
        {:noreply,
         socket
         |> put_flash(:info, "Report submitted for restricted moderator review.")
         |> push_navigate(to: ~p"/moderation/cases/#{case_record.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :report))}

      error ->
        {:noreply,
         socket
         |> assign(:form, report_form(attrs))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("submit", _params, socket) do
    {:noreply, put_flash(socket, :error, "Complete the report before submitting it.")}
  end

  defp initial_params(params) do
    %{
      "subject_type" => query_value(params, "subject_type", "repository"),
      "subject_id" => query_value(params, "subject_id", ""),
      "reason" => query_value(params, "reason", "unsafe_disclosure"),
      "description" => ""
    }
  end

  defp query_value(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _other -> default
    end
  end

  defp report_form(attrs), do: to_form(attrs, as: :report)

  defp error_message({:error, :rate_limited}),
    do: "You have reached the daily report limit. Try again later."

  defp error_message({:error, :subject_not_found}),
    do: "That content could not be found or is not visible to your account."

  defp error_message({:error, :unauthorized}),
    do: "Your account is not authorized to submit this report."

  defp error_message({:error, :invalid_report}), do: "The report is incomplete."
  defp error_message({:error, _reason}), do: "The report could not be submitted."
end
