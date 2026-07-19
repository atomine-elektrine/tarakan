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
         |> assign(:repositories, Profiles.list_repositories(account))
         |> assign(:reviews, Profiles.list_reviews(account))
         |> assign(:findings, Profiles.list_findings(account))
         |> assign(:checks, Profiles.list_checks(account))}
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
  def short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
  def short_sha(_sha), do: nil

  @doc false
  def review_kind_label("code_review"), do: "Code review"
  def review_kind_label("threat_model"), do: "Threat model"
  def review_kind_label("privacy_review"), do: "Privacy review"
  def review_kind_label("business_logic"), do: "Business logic"
  def review_kind_label(other) when is_binary(other), do: String.replace(other, "_", " ")
  def review_kind_label(_other), do: "Report"

  @doc false
  def review_status_label("accepted"), do: "Accepted"
  def review_status_label("quarantined"), do: "Quarantined"
  def review_status_label("rejected"), do: "Rejected"
  def review_status_label("contested"), do: "Contested"
  def review_status_label(other) when is_binary(other), do: String.capitalize(other)
  def review_status_label(_other), do: nil

  @doc false
  def provider_label("github"), do: "GitHub"
  def provider_label("gitlab"), do: "GitLab"
  def provider_label(other), do: String.capitalize(other)

  @doc false
  def check_path(%{public_id: public_id}) when is_binary(public_id) do
    ~p"/findings/#{public_id}"
  end

  def check_path(%{repository: repository}) when not is_nil(repository) do
    TarakanWeb.RepositoryPaths.repository_security_path(repository)
  end

  def check_path(_entry), do: ~p"/"
end
