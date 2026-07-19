defmodule TarakanWeb.Plugs.CodeBrowserRateLimit do
  @moduledoc false

  import Plug.Conn

  alias Tarakan.RateLimiter

  @defaults [request_limit: 180, window_seconds: 60]
  @unlimited_roles ~w(admin moderator)

  def init(opts) do
    configured = Application.get_env(:tarakan, __MODULE__, [])
    @defaults |> Keyword.merge(configured) |> Keyword.merge(opts)
  end

  def call(conn, opts) do
    cond do
      not code_browser_path?(conn.path_info) ->
        conn

      unlimited_actor?(conn) ->
        conn

      true ->
        check_request(conn, opts)
    end
  end

  defp unlimited_actor?(conn) do
    case conn.assigns[:current_scope] do
      %{platform_role: role} when role in @unlimited_roles -> true
      %{account: %{platform_role: role}} when role in @unlimited_roles -> true
      _ -> false
    end
  end

  defp check_request(conn, opts) do
    limit = Keyword.fetch!(opts, :request_limit)
    window = Keyword.fetch!(opts, :window_seconds)

    case RateLimiter.check({:code_browser_http, remote_ip(conn)}, limit, window) do
      :ok ->
        conn

      {:error, _reason, retry_after} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(:too_many_requests, "Too many source-browser requests. Try again shortly.\n")
        |> halt()
    end
  end

  defp code_browser_path?(["findings", _finding_ref, "code"]), do: true
  defp code_browser_path?([first, _name]), do: repository_segment?(first)
  defp code_browser_path?([first, _owner, _name]), do: repository_segment?(first)
  defp code_browser_path?([first, _second, "code" | _rest]), do: repository_segment?(first)

  defp code_browser_path?([first, _second, _third, "security"]),
    do: repository_segment?(first)

  defp code_browser_path?([first, _second, _third, "code" | _rest]),
    do: repository_segment?(first)

  defp code_browser_path?(_path), do: false

  # A repository path leads with a host (domain or legacy slug) or an
  # account handle; fixed-route prefixes are reserved handles and excluded.
  defp repository_segment?(segment) do
    Tarakan.Hosts.host_segment?(segment) or
      not Tarakan.Accounts.Account.reserved_handle?(segment)
  end

  defp remote_ip(conn), do: TarakanWeb.Plugs.ClientIp.remote_ip_string(conn)
end
