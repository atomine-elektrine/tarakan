defmodule Tarakan.GitLab.OAuthStub do
  @moduledoc false

  @behaviour Tarakan.GitLab.OAuthClient

  @impl true
  def exchange_code("valid-gitlab-code", verifier, redirect_uri)
      when is_binary(verifier) and is_binary(redirect_uri),
      do: {:ok, "temporary-gitlab-user-token"}

  def exchange_code(_code, _verifier, _redirect_uri), do: {:error, :authorization_failed}

  @impl true
  def fetch_user("temporary-gitlab-user-token") do
    {:ok,
     %{
       provider_uid: 24_680,
       provider_login: "GitLabSignal",
       name: "GitLab Signal",
       avatar_url: "https://gitlab.com/uploads/-/system/user/avatar/24680/avatar.png",
       profile_url: "https://gitlab.com/GitLabSignal"
     }}
  end

  def fetch_user(_token), do: {:error, :authorization_failed}
end
