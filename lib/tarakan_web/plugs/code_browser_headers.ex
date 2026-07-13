defmodule TarakanWeb.Plugs.CodeBrowserHeaders do
  @moduledoc false

  import Plug.Conn, only: [put_resp_header: 3]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      default_code_path?(conn.path_info) ->
        put_resp_header(conn, "cache-control", "no-store")

      code_browser_path?(conn.path_info) ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-robots-tag", "noindex, nofollow")

      true ->
        conn
    end
  end

  # Repository roots: hosted /owner/name and remote /host/owner/name.
  defp default_code_path?([first, _name]), do: repository_segment?(first)
  defp default_code_path?(["findings", _finding_ref, "code"]), do: false
  defp default_code_path?([first, _owner, _name]), do: repository_segment?(first)
  defp default_code_path?(_path), do: false

  defp code_browser_path?(["findings", _finding_ref, "code"]), do: true
  defp code_browser_path?([first, _second, "code" | _rest]), do: repository_segment?(first)

  defp code_browser_path?([first, _second, _third, "code" | _rest]),
    do: repository_segment?(first)

  defp code_browser_path?(_path), do: false

  # A repository path leads with a host (domain or legacy slug) or an
  # account handle; fixed-route prefixes are reserved handles and excluded.
  defp repository_segment?(segment) do
    Tarakan.Hosts.host_segment?(segment) or
      not Tarakan.Accounts.Account.reserved_handle?(segment)
  end
end
