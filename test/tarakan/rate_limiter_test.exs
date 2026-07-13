defmodule Tarakan.RateLimiterTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [assign: 3]
  import Plug.Test, only: [conn: 2]

  alias Tarakan.Accounts.Scope
  alias Tarakan.RateLimiter
  alias TarakanWeb.Plugs.ApiRateLimit

  test "limits each key independently within a window" do
    key = {:test, System.unique_integer([:positive])}
    other_key = {:test, System.unique_integer([:positive])}

    assert :ok = RateLimiter.check(key, 2, 60)
    assert :ok = RateLimiter.check(key, 2, 60)
    assert {:error, :rate_limited, retry_after} = RateLimiter.check(key, 2, 60)
    assert retry_after in 1..60
    assert :ok = RateLimiter.check(other_key, 2, 60)
  end

  test "cleanup preserves live counters for windows longer than one minute" do
    key = {:long_window, System.unique_integer([:positive])}
    assert :ok = RateLimiter.check(key, 1, 3_600)

    send(RateLimiter, :cleanup)
    :sys.get_state(RateLimiter)

    assert {:error, :rate_limited, _retry_after} = RateLimiter.check(key, 1, 3_600)
  end

  test "the API plug rejects an IP bucket with retry metadata" do
    unique = System.unique_integer([:positive])
    remote_ip = {127, rem(unique, 250) + 1, rem(div(unique, 250), 250) + 1, 1}
    opts = ApiRateLimit.init(mode: :ip, request_limit: 1, window_seconds: 60)

    first = conn(:get, "/api/work") |> Map.put(:remote_ip, remote_ip) |> ApiRateLimit.call(opts)
    refute first.halted

    second = conn(:get, "/api/work") |> Map.put(:remote_ip, remote_ip) |> ApiRateLimit.call(opts)
    assert second.halted
    assert second.status == 429
    assert Plug.Conn.get_resp_header(second, "retry-after") != []
  end

  test "mutation limits are isolated by account and credential" do
    unique = System.unique_integer([:positive])
    opts = ApiRateLimit.init(mode: :actor, mutation_limit: 1, window_seconds: 60)

    scope = %Scope{account_id: unique, token_id: unique}
    first = conn(:post, "/api/work") |> assign(:current_scope, scope) |> ApiRateLimit.call(opts)
    refute first.halted

    second = conn(:post, "/api/work") |> assign(:current_scope, scope) |> ApiRateLimit.call(opts)
    assert second.halted
    assert second.status == 429

    other = %Scope{account_id: unique + 1, token_id: unique + 1}

    third = conn(:post, "/api/work") |> assign(:current_scope, other) |> ApiRateLimit.call(opts)
    refute third.halted
  end
end
