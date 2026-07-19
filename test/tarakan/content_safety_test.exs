defmodule Tarakan.ContentSafetyTest do
  use ExUnit.Case, async: true

  alias Tarakan.ContentSafety

  test "allows ordinary finding text" do
    assert :ok =
             ContentSafety.scan_text(
               "SQL injection via string concat in lib/app/query.ex lines 40-52"
             )
  end

  test "rejects PEM private keys" do
    text = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF7P
    -----END RSA PRIVATE KEY-----
    """

    assert {:error, :secrets_detected} = ContentSafety.scan_text(text)
  end

  test "rejects GitHub tokens" do
    assert {:error, :secrets_detected} =
             ContentSafety.scan_text("token ghp_abcdefghijklmnopqrstuvwxyz012345")
  end

  test "rejects AWS access key ids" do
    assert {:error, :secrets_detected} =
             ContentSafety.scan_text("found AKIAIOSFODNN7EXAMPLE in config")
  end

  test "scan_submission checks notes and findings json" do
    # Build at runtime so the fixture is not a contiguous secret in source.
    stripe_shaped = "sk" <> "_live_" <> String.duplicate("x", 24)

    assert {:error, :secrets_detected} =
             ContentSafety.scan_submission(%{
               "notes" => "see key #{stripe_shaped}",
               "findings_json" => "{\"findings\":[]}"
             })
  end
end
