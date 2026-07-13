defmodule Tarakan.Accounts.AccessControlTest do
  use Tarakan.DataCase, async: false

  import Ecto.Query
  import Tarakan.AccountsFixtures

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, ApiCredentials, SshKeys}
  alias Tarakan.Repo

  @moduletag :tmp_dir

  describe "suspended and banned accounts" do
    setup do
      account = account_fixture() |> set_password()
      %{account: account, password: valid_account_password()}
    end

    test "password login is refused", %{account: account, password: password} do
      lock_account(account, "banned")

      refute Accounts.get_account_by_identifier_and_password(account.email, password)
      refute Accounts.get_account_by_identifier_and_password(account.handle, password)
    end

    test "existing session tokens stop working", %{account: account} do
      token = Accounts.generate_account_session_token(account)
      assert Accounts.get_account_by_session_token(token)

      lock_account(account, "suspended")
      refute Accounts.get_account_by_session_token(token)
    end

    test "API credentials stop authenticating", %{account: account} do
      assert {:ok, token, _credential} =
               ApiCredentials.create(account, %{name: "worker", scopes: ["tasks:read"]})

      assert {:ok, _account, _credential} = ApiCredentials.authenticate(token)

      lock_account(account, "banned")
      assert :error = ApiCredentials.authenticate(token)
    end

    test "invalidate_account_access revokes sessions, credentials, and SSH keys", %{
      account: account,
      tmp_dir: tmp_dir
    } do
      _session = Accounts.generate_account_session_token(account)
      assert {:ok, api_token, _credential} = ApiCredentials.create(account, %{name: "cli"})

      public_key = generate_ed25519_public_key(tmp_dir)

      assert {:ok, _key} =
               SshKeys.add_key(account, %{"name" => "laptop", "public_key" => public_key})

      assert SshKeys.list_for_account(account) != []

      assert :ok = Accounts.invalidate_account_access(account.id, purge_credentials: true)

      assert Repo.all(from t in Accounts.AccountToken, where: t.account_id == ^account.id) == []
      assert :error = Accounts.fetch_account_by_api_token(api_token)
      assert SshKeys.list_for_account(account) == []
    end

    test "session tokens are stored hashed" do
      account = account_fixture()
      raw = Accounts.generate_account_session_token(account)
      stored = Repo.get_by(Accounts.AccountToken, account_id: account.id)
      assert stored.token == Accounts.AccountToken.hash_token(raw)
      refute stored.token == raw
    end
  end

  defp lock_account(%Account{} = account, state) do
    account
    |> Account.authorization_changeset(%{
      state: state,
      platform_role: account.platform_role,
      trust_tier: account.trust_tier
    })
    |> Repo.update!()
  end

  defp generate_ed25519_public_key(tmp_dir) do
    path = Path.join(tmp_dir, "key-#{System.unique_integer([:positive])}")
    {_output, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-f", path, "-N", "", "-q"])
    File.read!(path <> ".pub")
  end
end
