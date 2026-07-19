defmodule Tarakan.RateLimiterTest do
  use Tarakan.DataCase, async: false

  alias Tarakan.RateLimiter

  test "shared postgres backend enforces fixed windows" do
    key = {:test_limit, System.unique_integer([:positive])}

    assert :ok = RateLimiter.check(key, 2, 60)
    assert :ok = RateLimiter.check(key, 2, 60)
    assert {:error, :rate_limited, retry} = RateLimiter.check(key, 2, 60)
    assert is_integer(retry) and retry > 0
  end
end
