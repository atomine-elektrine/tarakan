defmodule TarakanWeb.Plugs.CodeBrowserRateLimitTest do
  use Tarakan.DataCase, async: true

  import Plug.Test

  alias TarakanWeb.Plugs.CodeBrowserRateLimit

  test "is a no-op on code routes (mirrors serve unlimited code)" do
    opts = CodeBrowserRateLimit.init([])

    for path <- [
          "/findings/55d5c681-240a-4e3a-a1f8-45933a30c4ef/code",
          "/github.com/openai/codex",
          "/github.com/openai/codex/code"
        ] do
      conn = conn(:get, path) |> CodeBrowserRateLimit.call(opts)
      refute conn.halted
    end
  end

  test "is a no-op on unrelated pages" do
    opts = CodeBrowserRateLimit.init([])
    conn = conn(:get, "/") |> CodeBrowserRateLimit.call(opts)
    refute conn.halted
  end
end
