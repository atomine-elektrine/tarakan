defmodule Tarakan.GitHub.OAuth.HTTPClient do
  @moduledoc false

  @behaviour Tarakan.GitHub.OAuthClient

  @impl true
  def exchange_code(code, verifier, redirect_uri) do
    github_config = Tarakan.GitHub.OAuth.github_config()

    form = [
      client_id: github_config[:client_id],
      client_secret: github_config[:client_secret],
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri
    ]

    case Req.post("https://github.com/login/oauth/access_token",
           form: form,
           headers: [{"accept", "application/json"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      _other -> {:error, :authorization_failed}
    end
  end

  @impl true
  def fetch_user(token) do
    github_config = Tarakan.GitHub.OAuth.github_config()

    headers = [
      {"accept", "application/vnd.github+json"},
      {"authorization", "Bearer #{token}"},
      {"user-agent", "Tarakan/0.1 (https://tarakan.lol)"},
      {"x-github-api-version", github_config[:api_version]}
    ]

    case Req.get("https://api.github.com/user", headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           provider_uid: body["id"],
           provider_login: body["login"],
           name: body["name"],
           avatar_url: body["avatar_url"],
           profile_url: body["html_url"]
         }}

      _other ->
        {:error, :authorization_failed}
    end
  end
end
