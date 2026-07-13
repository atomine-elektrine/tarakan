defmodule Tarakan.GitHub.OAuth do
  @moduledoc """
  GitHub App user authorization with state and PKCE.
  """

  @authorize_url "https://github.com/login/oauth/authorize"

  def configured? do
    config = github_config()
    present?(config[:client_id]) and present?(config[:client_secret])
  end

  def authorize_url(state, code_challenge, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => github_config()[:client_id],
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256",
        "redirect_uri" => redirect_uri,
        "state" => state
      })

    "#{@authorize_url}?#{query}"
  end

  def exchange_code(code, verifier, redirect_uri) do
    oauth_client().exchange_code(code, verifier, redirect_uri)
  end

  def fetch_user(token), do: oauth_client().fetch_user(token)

  def generate_state do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  def generate_pkce do
    verifier = 64 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    challenge =
      verifier
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    {verifier, challenge}
  end

  def valid_state?(expected, received) when is_binary(expected) and is_binary(received) do
    byte_size(expected) == byte_size(received) and Plug.Crypto.secure_compare(expected, received)
  end

  def valid_state?(_expected, _received), do: false

  def github_config, do: Application.fetch_env!(:tarakan, :github)

  defp oauth_client, do: Application.fetch_env!(:tarakan, :github_oauth_client)
  defp present?(value), do: is_binary(value) and value != ""
end
