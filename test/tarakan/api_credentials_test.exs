defmodule Tarakan.ApiCredentialsTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts.ApiCredentials

  test "credentials are named, scoped, independently revocable, and expire" do
    account = account_fixture()

    assert {:ok, first_token, first} =
             ApiCredentials.create(account, %{name: "laptop", scopes: ["tasks:read"]})

    assert {:ok, second_token, second} =
             ApiCredentials.create(account, %{name: "desktop", scopes: ["tasks:claim"]})

    assert first_token != second_token
    assert first.token_hash != first_token
    assert first.expires_at
    assert {:ok, fetched_account, fetched} = ApiCredentials.authenticate(first_token)
    assert fetched_account.id == account.id
    assert fetched.id == first.id
    assert fetched.last_used_at
    assert ApiCredentials.scope_granted?(fetched, "tasks:read")
    refute ApiCredentials.scope_granted?(fetched, "tasks:claim")

    assert {:ok, _credential} = ApiCredentials.revoke(account, first.id)
    assert :error = ApiCredentials.authenticate(first_token)
    assert {:ok, _, %{id: second_id}} = ApiCredentials.authenticate(second_token)
    assert second_id == second.id
  end

  test "rejects unknown scopes" do
    assert {:error, changeset} =
             ApiCredentials.create(account_fixture(), %{
               name: "overpowered",
               scopes: ["moderation:write"]
             })

    assert "has an invalid entry" in errors_on(changeset).scopes
  end

  test "callers cannot extend credential lifetime and malformed tokens never authenticate" do
    account = account_fixture()
    requested = DateTime.add(DateTime.utc_now(), 365, :day)

    assert {:ok, token, credential} =
             ApiCredentials.create(account, %{name: "bounded", expires_at: requested})

    assert DateTime.diff(credential.expires_at, DateTime.utc_now(), :day) in 29..30
    assert {:ok, _, _} = ApiCredentials.authenticate(token)
    assert :error = ApiCredentials.authenticate("trkn_" <> String.duplicate("!", 43))
    assert :error = ApiCredentials.authenticate("trkn_short")
    assert :error = ApiCredentials.authenticate(String.duplicate("x", 10_000))
  end

  test "limits active credentials and prevents cross-account revocation" do
    account = account_fixture()
    other = account_fixture()

    credentials =
      for number <- 1..10 do
        assert {:ok, _token, credential} =
                 ApiCredentials.create(account, %{name: "worker #{number}"})

        credential
      end

    assert {:error, :credential_limit} =
             ApiCredentials.create(account, %{name: "one too many"})

    assert {:error, :not_found} = ApiCredentials.revoke(other, hd(credentials).id)
    assert {:ok, _credential} = ApiCredentials.revoke(account, hd(credentials).id)
    assert {:ok, _token, _credential} = ApiCredentials.create(account, %{name: "replacement"})
  end
end
