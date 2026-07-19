defmodule TarakanWeb.Plugs.CodeBrowserRateLimitTest do
  use Tarakan.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias TarakanWeb.Plugs.CodeBrowserRateLimit

  test "limits code and finding routes before LiveView authorization" do
    opts = CodeBrowserRateLimit.init(request_limit: 1, window_seconds: 60)
    # Unique IP per run so shared postgres buckets do not collide across tests.
    remote_ip = {10, 44, 55, System.unique_integer([:positive]) |> rem(200) |> Kernel.+(1)}

    first = conn(:get, "/findings/55d5c681-240a-4e3a-a1f8-45933a30c4ef/code")
    first = %{first | remote_ip: remote_ip} |> CodeBrowserRateLimit.call(opts)
    refute first.halted

    limited = conn(:get, "/github.com/openai/codex")
    limited = %{limited | remote_ip: remote_ip} |> CodeBrowserRateLimit.call(opts)

    assert limited.halted
    assert limited.status == 429
    assert get_resp_header(limited, "retry-after") != []
  end

  test "does not spend the code-browser budget on unrelated pages" do
    opts = CodeBrowserRateLimit.init(request_limit: 1, window_seconds: 60)
    conn = conn(:get, "/") |> CodeBrowserRateLimit.call(opts)

    refute conn.halted
  end
end
