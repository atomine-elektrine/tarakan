defmodule TarakanWeb.RepositoryLive.Index do
  use TarakanWeb, :live_view

  alias Tarakan.Activity
  alias Tarakan.Community
  alias Tarakan.Repositories
  alias Tarakan.Scans
  alias Tarakan.Work
  alias TarakanWeb.Presence

  @presence_topic "registry:observers"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Repositories.subscribe()
      Activity.subscribe()
      Community.subscribe()
      Phoenix.PubSub.subscribe(Tarakan.PubSub, @presence_topic)

      {:ok, _ref} = Presence.track(self(), @presence_topic, socket.id, %{})
    end

    {:ok,
     socket
     |> assign(:page_title, "Turn on the lights.")
     |> assign(
       :meta_description,
       "Turn on the lights. Local agents. Public record. Pick up security jobs, review pinned commits, file findings."
     )
     |> assign(:canonical_path, ~p"/")
     |> assign(:stats, Repositories.registry_stats())
     |> assign(:contributor_count, Scans.public_contributor_count())
     |> assign(:open_tasks, Work.list_open_public_tasks())
     |> assign(:scan_queue, scan_queue())
     |> assign(:observer_count, observer_count())
     |> assign(:shouts, chronological_shouts(socket.assigns.current_scope))
     |> assign(:shout_form, to_form(Community.change_shout(), as: :shout))
     |> assign(:shout_form_version, 0)
     |> assign(:can_moderate_shouts, Community.can_moderate?(socket.assigns.current_scope))
     |> assign(:search_query, "")
     |> assign(:search_results, [])}
  end

  @queue_limit 8

  # list_shouts/2 serves "the most recent N", newest first. The shoutbox reads
  # like a chat log - oldest visible message at the top, newest at the bottom.
  defp chronological_shouts(scope) do
    scope |> Community.list_shouts() |> Enum.reverse()
  end

  defp scan_queue do
    Repositories.list_reviewable_repositories(
      status: "unscanned",
      limit: @queue_limit,
      listing: :listed
    )
  end

  defp refresh_collective(socket) do
    socket
    |> assign(:contributor_count, Scans.public_contributor_count())
    |> assign(:open_tasks, Work.list_open_public_tasks())
    |> assign(:scan_queue, scan_queue())
  end

  @impl true
  def handle_info({:activity, entry}, socket) do
    _entry = entry
    {:noreply, refresh_collective(socket)}
  end

  def handle_info({:repository_registered, _repository}, socket) do
    {:noreply,
     socket
     |> assign(:stats, Repositories.registry_stats())
     |> assign(:scan_queue, scan_queue())}
  end

  def handle_info({:repository_record_updated, repository}, socket) do
    _repository = repository

    {:noreply,
     socket
     |> assign(:stats, Repositories.registry_stats())
     |> refresh_collective()}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :observer_count, observer_count())}
  end

  def handle_info({event, _shout}, socket) when event in [:shout_posted, :shout_removed] do
    {:noreply, assign(socket, :shouts, chronological_shouts(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("search", params, socket) do
    query = params |> Map.get("q", "") |> String.trim()

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, Repositories.search_repositories(query))}
  end

  def handle_event(
        "post_shout",
        %{"shout" => attrs},
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    case Community.create_shout(socket.assigns.current_scope, attrs) do
      {:ok, _shout} ->
        {:noreply,
         socket
         |> assign(:shout_form, to_form(Community.change_shout(), as: :shout))
         |> update(:shout_form_version, &(&1 + 1))
         |> assign(:shouts, chronological_shouts(socket.assigns.current_scope))}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Slow down—a few shouts per minute is plenty.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:shout_form, to_form(changeset, as: :shout))
         |> put_flash(:error, "Write a message before sending.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That shout could not be posted.")}
    end
  end

  def handle_event("post_shout", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/accounts/log-in")}
  end

  def handle_event(
        "remove_shout",
        %{"id" => id},
        %{assigns: %{current_scope: %{account: account}}} = socket
      )
      when not is_nil(account) do
    with {:ok, shout} <- Community.get_shout(id),
         {:ok, _removed} <-
           Community.remove_shout(socket.assigns.current_scope, shout, %{
             "removed_reason" => "community_moderation"
           }) do
      {:noreply, assign(socket, :shouts, chronological_shouts(socket.assigns.current_scope))}
    else
      _error -> {:noreply, put_flash(socket, :error, "That shout could not be removed.")}
    end
  end

  def handle_event("remove_shout", _params, socket) do
    {:noreply, put_flash(socket, :error, "That shout could not be removed.")}
  end

  defp observer_count do
    @presence_topic |> Presence.list() |> map_size()
  end

  defp shout_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d · %H:%M")
end
