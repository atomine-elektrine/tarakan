defmodule TarakanWeb.Plugs.CodeBrowserRateLimit do
  @moduledoc """
  Formerly IP-throttled code routes. Code is served from local git mirrors;
  this plug is now a no-op so navigation is never blocked as "busy".
  """

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts), do: conn
end
