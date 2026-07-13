defmodule Tarakan.GitLab.OAuth.HTTPClient do
  @moduledoc false

  @behaviour Tarakan.GitLab.OAuthClient

  alias Tarakan.GitLab.OAuth

  @impl true
  def exchange_code(code, verifier, redirect_uri) do
    config = OAuth.gitlab_config()

    form = [
      client_id: config[:client_id],
      client_secret: config[:client_secret],
      code: code,
      code_verifier: verifier,
      grant_type: "authorization_code",
      redirect_uri: redirect_uri
    ]

    case Req.post("#{OAuth.base_url()}/oauth/token",
           form: form,
           headers: [{"accept", "application/json"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      _other -> {:error, :authorization_failed}
    end
  end

  @impl true
  def fetch_user(token) do
    headers = [
      {"accept", "application/json"},
      {"authorization", "Bearer #{token}"},
      {"user-agent", "Tarakan/0.1 (https://tarakan.lol)"}
    ]

    case Req.get("#{OAuth.base_url()}/api/v4/user", headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           provider_uid: body["id"],
           provider_login: body["username"],
           name: body["name"],
           avatar_url: body["avatar_url"],
           profile_url: body["web_url"]
         }}

      _other ->
        {:error, :authorization_failed}
    end
  end
end
