defmodule TarakanWeb.SafeRedirectTest do
  use ExUnit.Case, async: true

  alias TarakanWeb.SafeRedirect

  test "keeps same-origin absolute paths" do
    assert SafeRedirect.local_path("/") == "/"

    assert SafeRedirect.local_path("/accounts/settings?tab=identities") ==
             "/accounts/settings?tab=identities"
  end

  test "rejects authority paths, backslashes, controls, and encoded variants" do
    malicious_paths = [
      "https://attacker.example/",
      "//attacker.example/",
      "/\\attacker.example/",
      "/%5cattacker.example/",
      "/%255cattacker.example/",
      "/%25255cattacker.example/",
      "/%2f%2fattacker.example/",
      "/%252f%252fattacker.example/",
      "/safe%0d%0aLocation:%20https://attacker.example/"
    ]

    for path <- malicious_paths do
      assert SafeRedirect.local_path(path) == "/", "expected #{inspect(path)} to be rejected"
    end
  end

  test "uses the caller's fallback for invalid input" do
    assert SafeRedirect.local_path("//attacker.example", "/accounts/log-in") ==
             "/accounts/log-in"

    assert SafeRedirect.local_path(nil, "/accounts/log-in") == "/accounts/log-in"
  end
end
