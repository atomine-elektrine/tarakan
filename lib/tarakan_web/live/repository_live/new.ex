defmodule TarakanWeb.RepositoryLive.New do
  use TarakanWeb, :live_view

  alias Tarakan.HostedRepositories
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias TarakanWeb.RepositoryPaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Add repository")
     |> assign(:remote_form, remote_form(%{}))
     |> assign(:form, hosted_form(socket, %{}))}
  end

  @impl true
  def handle_event("validate_remote", %{"repository" => params}, socket) do
    form =
      params
      |> Repositories.registration_changeset()
      |> Map.put(:action, :validate)
      |> to_form(as: :repository)

    {:noreply, assign(socket, :remote_form, form)}
  end

  def handle_event("register_remote", %{"repository" => %{"url" => url} = params}, socket) do
    case Repositories.register_github_repository(url, socket.assigns.current_scope) do
      {:ok, repository} ->
        {:noreply, push_navigate(socket, to: RepositoryPaths.repository_path(repository))}

      {:error, reason} ->
        {:noreply, assign_remote_error(socket, params, registration_error_message(reason))}
    end
  end

  def handle_event("validate", %{"repository" => params}, socket) do
    form =
      socket
      |> hosted_changeset(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :repository)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("create", %{"repository" => params}, socket) do
    case HostedRepositories.create(socket.assigns.current_scope, params) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository created. Push a branch to publish code.")
         |> push_navigate(to: RepositoryPaths.repository_path(repository))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :repository))}

      {:error, :registration_limit} ->
        {:noreply,
         put_flash(socket, :error, "You have reached today's repository registration limit.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "The repository could not be created. Try again shortly.")}
    end
  end

  defp assign_remote_error(socket, params, message) do
    changeset = Repositories.registration_changeset(params)

    form =
      changeset
      |> Ecto.Changeset.add_error(:url, message)
      |> Map.put(:action, :validate)
      |> to_form(as: :repository)

    assign(socket, :remote_form, form)
  end

  defp registration_error_message(:invalid_github_repository),
    do: "enter a valid public GitHub repository"

  defp registration_error_message(:not_found), do: "repository was not found or is not public"
  defp registration_error_message(:not_public), do: "repository was not found or is not public"

  defp registration_error_message(:rate_limited),
    do: "GitHub is rate limiting requests; try again shortly"

  defp registration_error_message(:request_limited),
    do: "too many repository requests; try again shortly"

  defp registration_error_message(:unavailable),
    do: "GitHub could not be reached; try again shortly"

  defp registration_error_message(:registration_limit),
    do: "daily repository registration limit reached"

  defp registration_error_message(:unauthorized),
    do: "this account cannot register repositories"

  defp registration_error_message(_reason), do: "repository could not be registered"

  defp remote_form(params) do
    params
    |> Repositories.registration_changeset()
    |> to_form(as: :repository)
  end

  defp hosted_form(socket, params) do
    socket
    |> hosted_changeset(params)
    |> to_form(as: :repository)
  end

  defp hosted_changeset(socket, params) do
    Repository.hosted_changeset(
      %Repository{},
      params,
      socket.assigns.current_scope.account.handle
    )
  end
end
