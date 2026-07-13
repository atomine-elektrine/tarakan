defmodule TarakanWeb.AccountLive.Profile do
  use TarakanWeb, :live_view

  alias Tarakan.Profiles
  alias Tarakan.Reputation

  @impl true
  def mount(%{"handle" => handle}, _session, socket) do
    case Profiles.get_profile(handle) do
      nil ->
        raise Ecto.NoResultsError, queryable: Tarakan.Accounts.Account

      account ->
        {:ok,
         socket
         |> assign(:page_title, "@#{account.handle}")
         |> assign(:meta_description, meta_description(account))
         |> assign(:canonical_path, ~p"/#{account.handle}")
         |> assign(:account, account)
         |> assign(:reputation, Reputation.score(account))
         |> assign(:stats, Profiles.contribution_stats(account))
         |> assign(:activity, Profiles.recent_activity(account))}
    end
  end

  defp meta_description(account) do
    "@#{account.handle} on Tarakan - #{tier_label(account.trust_tier)} contributor to the public security record for open source."
  end

  @doc false
  def tier_label("reviewer"), do: "Reviewer"
  def tier_label("contributor"), do: "Contributor"
  def tier_label(_new), do: "New"

  @doc false
  def role_label("admin"), do: "Admin"
  def role_label("moderator"), do: "Moderator"
  def role_label(_member), do: nil

  @doc false
  def joined_on(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%B %Y")
  def joined_on(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%B %Y")

  @doc false
  def activity_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")

  @doc false
  def provider_label("github"), do: "GitHub"
  def provider_label("gitlab"), do: "GitLab"
  def provider_label(other), do: String.capitalize(other)
end
