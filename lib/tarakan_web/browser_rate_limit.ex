defmodule TarakanWeb.BrowserRateLimit do
  @moduledoc "Central rate profiles for browser authentication and email workflows."

  alias Tarakan.RateLimiter

  @defaults %{
    login_ip: {10, 60},
    login_pair: {6, 300},
    magic_ip: {5, 3_600},
    magic_email: {3, 3_600},
    registration_ip: {5, 3_600},
    # Device-auth start is unauthenticated; keep it well below general API limits.
    client_auth_start_ip: {10, 60},
    # Exchange is polled every @poll_interval_seconds (2s) while awaiting approval,
    # i.e. ~30/min for one client. Allow generous headroom for jitter and several
    # clients sharing one NAT/CI egress IP so honest polling never trips a 429.
    client_auth_exchange_ip: {120, 60}
  }

  def allowed?(profile, key) when is_atom(profile) do
    {limit, window_seconds} =
      :tarakan
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(profile, Map.fetch!(@defaults, profile))

    RateLimiter.check({profile, key}, limit, window_seconds) == :ok
  end
end
