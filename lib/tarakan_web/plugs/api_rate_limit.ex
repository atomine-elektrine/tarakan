defmodule TarakanWeb.Plugs.ApiRateLimit do
  @moduledoc """
  Applies independent IP, account, token, and mutation limits to API traffic.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Tarakan.RateLimiter

  @defaults [request_limit: 120, mutation_limit: 20, window_seconds: 60]

  def init(opts) do
    configured = Application.get_env(:tarakan, __MODULE__, [])
    @defaults |> Keyword.merge(configured) |> Keyword.merge(opts)
  end

  def call(conn, opts) do
    mode = Keyword.fetch!(opts, :mode)
    request_limit = Keyword.fetch!(opts, :request_limit)
    mutation_limit = Keyword.fetch!(opts, :mutation_limit)
    window_seconds = Keyword.fetch!(opts, :window_seconds)

    checks =
      case mode do
        :ip -> [{{:api_ip, remote_ip(conn)}, request_limit}]
        :actor -> actor_checks(conn, request_limit, mutation_limit)
      end

    case Enum.find_value(checks, &limited?(&1, window_seconds)) do
      nil -> conn
      retry_after -> reject(conn, retry_after)
    end
  end

  defp actor_checks(conn, request_limit, mutation_limit) do
    scope = conn.assigns[:current_scope]
    account_id = scope && scope.account_id
    token_id = scope && scope.token_id

    base = [
      {{:api_account, account_id || :anonymous}, request_limit},
      {{:api_token, token_id || :session}, request_limit}
    ]

    if conn.method in ~w(POST PUT PATCH DELETE) do
      [
        {{:api_account_mutation, account_id || :anonymous}, mutation_limit},
        {{:api_token_mutation, token_id || :session}, mutation_limit}
        | base
      ]
    else
      base
    end
  end

  defp limited?({key, limit}, window_seconds) do
    case RateLimiter.check(key, limit, window_seconds) do
      :ok -> nil
      {:error, _reason, retry_after} -> retry_after
    end
  end

  defp reject(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{error: "rate limit exceeded", retry_after: retry_after})
    |> halt()
  end

  defp remote_ip(conn), do: TarakanWeb.Plugs.ClientIp.remote_ip_string(conn)
end
