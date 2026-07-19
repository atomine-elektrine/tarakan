defmodule Tarakan.AbuseTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Abuse
  alias Tarakan.Accounts.Account

  test "quorum requires active standing; probation never counts" do
    reviewer =
      %Account{
        state: "active",
        trust_tier: "reviewer",
        platform_role: "member",
        inserted_at: DateTime.utc_now()
      }

    assert Abuse.quorum_eligible?(reviewer)

    aged_contributor =
      %Account{
        state: "active",
        trust_tier: "contributor",
        platform_role: "member",
        inserted_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
      }

    assert Abuse.quorum_eligible?(aged_contributor)

    fresh_contributor =
      %Account{
        state: "active",
        trust_tier: "new",
        platform_role: "member",
        inserted_at: DateTime.utc_now()
      }

    refute Abuse.quorum_eligible?(fresh_contributor)

    probation =
      %Account{
        state: "probation",
        trust_tier: "reviewer",
        platform_role: "member",
        inserted_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
      }

    refute Abuse.quorum_eligible?(probation)
  end

  test "client IP hashes are stable and non-empty" do
    hash = Abuse.hash_client_ip("203.0.113.10")
    assert is_binary(hash)
    assert byte_size(hash) == 32
    assert hash == Abuse.hash_client_ip("203.0.113.10")
    assert Abuse.hash_client_ip(nil) == nil
  end
end
