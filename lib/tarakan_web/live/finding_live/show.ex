defmodule TarakanWeb.FindingLive.Show do
  use TarakanWeb, :live_view

  alias Tarakan.Discussion
  alias Tarakan.FindingMemory
  alias Tarakan.Reputation
  alias Tarakan.Scans
  alias Tarakan.Scans.Finding

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    {scan, finding} = fetch_finding!(socket, public_id)

    if connected?(socket) do
      Scans.subscribe(scan.repository_id)
      Discussion.subscribe(finding.id)
      Reputation.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, finding.title)
     |> assign(:meta_description, meta_description(scan, finding))
     |> assign(:canonical_path, ~p"/findings/#{finding.public_id}")
     |> assign(:comment_body, "")
     |> assign(:reply_to, nil)
     |> assign(:can_vote, can_vote?(socket))
     |> assign_record(scan, finding)
     |> load_comments()
     |> load_votes()}
  end

  @impl true
  def handle_event(
        "record_finding_verdict",
        %{"verdict" => verdict} = params,
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    attrs = %{
      "commit_sha" => socket.assigns.scan.commit_sha,
      "verdict" => verdict,
      "provenance" => "human",
      "notes" => params["notes"]
    }

    case FindingMemory.record_check(
           socket.assigns.current_scope,
           socket.assigns.repository,
           socket.assigns.finding.canonical_finding.public_id,
           attrs
         ) do
      {:ok, _check, _canonical} ->
        {:noreply, socket |> refresh_record() |> load_votes()}

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

  def handle_event("reply_to", %{"parent" => parent_id}, socket) do
    {:noreply, assign(socket, :reply_to, parent_id)}
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :reply_to, nil)}
  end

  def handle_event(
        "post_comment",
        %{"body" => body} = params,
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    attrs = %{"body" => body, "parent_id" => params["parent_id"]}

    case Discussion.create_comment(socket.assigns.current_scope, socket.assigns.finding, attrs) do
      {:ok, _comment} ->
        {:noreply,
         socket
         |> assign(:comment_body, "")
         |> assign(:reply_to, nil)
         |> load_comments()}

      {:error, :too_deep} ->
        {:noreply, put_flash(socket, :error, "This thread is too deeply nested to reply to.")}

      {:error, reason} when reason in [:invalid_parent, :not_found] ->
        {:noreply, put_flash(socket, :error, "That comment is no longer available.")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "Your account cannot post to the discussion right now.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Write a comment before posting.")}
    end
  end

  def handle_event("post_comment", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  def handle_event(
        "remove_comment",
        %{"id" => id, "reason" => reason},
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    with {:ok, comment} <- Discussion.get_comment(id),
         {:ok, _removed} <-
           Discussion.remove_comment(socket.assigns.current_scope, comment, %{
             "removed_reason" => reason
           }) do
      {:noreply, load_comments(socket)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "The comment could not be removed.")}
    end
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
        {:noreply, socket |> load_votes() |> load_comments()}

      {:error, :own_content} ->
        {:noreply, put_flash(socket, :error, "You cannot vote on your own contribution.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Your vote could not be recorded.")}
    end
  end

  def handle_event("vote", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  @impl true
  def handle_info({:scan_updated, %{id: scan_id}}, %{assigns: %{scan: %{id: scan_id}}} = socket) do
    {:noreply, refresh_record(socket)}
  end

  def handle_info({event, _comment}, socket)
      when event in [:comment_posted, :comment_removed] do
    {:noreply, socket |> load_comments() |> load_votes()}
  end

  def handle_info({:vote_changed, _type, _id}, socket) do
    {:noreply, load_votes(socket)}
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  defp load_comments(socket) do
    comments = Discussion.list_comments(socket.assigns.current_scope, socket.assigns.finding)

    socket
    |> assign(:comments, comments)
    |> assign(:comment_count, Enum.count(flatten_comments(comments)))
    |> assign(
      :can_moderate_comments,
      Discussion.can_moderate?(socket.assigns.current_scope, socket.assigns.finding)
    )
  end

  defp load_votes(socket) do
    account_id = current_account_id(socket)

    comment_ids =
      socket.assigns |> Map.get(:comments, []) |> flatten_comments() |> Enum.map(& &1.id)

    socket
    |> assign(
      :finding_votes,
      Reputation.vote_summary(
        "canonical_finding",
        socket.assigns.finding.canonical_finding.id,
        account_id
      )
    )
    |> assign(:comment_votes, Reputation.vote_summaries("comment", comment_ids, account_id))
  end

  defp current_account_id(%{assigns: %{current_scope: %{account: %{id: id}}}}), do: id
  defp current_account_id(_socket), do: nil

  defp can_vote?(socket), do: not is_nil(current_account_id(socket))

  defp flatten_comments(comments) do
    Enum.flat_map(comments, fn comment -> [comment | flatten_comments(comment.replies)] end)
  end

  defp refresh_record(socket) do
    {scan, finding} = fetch_finding!(socket, socket.assigns.finding.public_id)
    assign_record(socket, scan, finding)
  end

  defp assign_record(socket, scan, finding) do
    socket
    |> assign(:scan, scan)
    |> assign(:finding, finding)
    |> assign(:repository, scan.repository)
    |> assign(
      :finding_checks,
      FindingMemory.list_checks(finding.canonical_finding.id, scan.commit_sha)
    )
    |> assign(
      :can_check,
      FindingMemory.can_check?(
        socket.assigns.current_scope,
        scan.repository,
        finding.canonical_finding.public_id,
        scan.commit_sha
      )
    )
    |> assign(:review_stake, Reputation.review_stake(scan))
  end

  defp fetch_finding!(socket, public_id) do
    case Scans.get_finding(socket.assigns.current_scope, public_id) do
      # Attach the resolved scan so Discussion can read the repository id
      # without another query.
      {:ok, {scan, finding}} -> {scan, %{finding | scan: scan}}
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Finding
    end
  end

  # Search snippets truncate around 160 characters; lead with the facts that
  # identify the finding before the free-text description.
  defp meta_description(scan, finding) do
    prefix =
      "#{String.capitalize(finding.severity)} severity finding in " <>
        "#{scan.repository.owner}/#{scan.repository.name} (#{finding.file_path}): "

    truncate(prefix <> String.replace(finding.description, ~r/\s+/, " "), 160)
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    String.slice(text, 0, max - 1) <> "…"
  end

  defp record_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp stake_label(:at_risk), do: "at risk (awaiting review)"
  defp stake_label(:returned), do: "returned (verified)"
  defp stake_label(:slashed), do: "slashed (refuted)"

  defp finding_lines(%{line_start: nil}), do: ""
  defp finding_lines(%{line_start: line, line_end: line}), do: ":#{line}"

  defp finding_lines(%{line_start: line_start, line_end: line_end}),
    do: ":#{line_start}-#{line_end}"
end
