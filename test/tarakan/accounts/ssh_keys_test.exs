defmodule Tarakan.Accounts.SshKeysTest do
  use Tarakan.DataCase, async: false

  import Tarakan.AccountsFixtures

  alias Tarakan.Accounts.{SshKey, SshKeys}

  @moduletag :tmp_dir

  defp generate_key(tmp_dir, type, opts \\ []) do
    path = Path.join(tmp_dir, "key-#{System.unique_integer([:positive])}")
    args = ["-t", type, "-f", path, "-N", "", "-q"] ++ Keyword.get(opts, :extra, [])
    {_output, 0} = System.cmd("ssh-keygen", args, stderr_to_stdout: true)
    File.read!(path <> ".pub")
  end

  test "registers ed25519, ecdsa, and 3072-bit RSA keys", %{tmp_dir: tmp_dir} do
    account = account_fixture()

    for {type, extra} <- [
          {"ed25519", []},
          {"ecdsa", []},
          {"rsa", ["-b", "3072"]}
        ] do
      public_key = generate_key(tmp_dir, type, extra: extra)

      assert {:ok, %SshKey{} = key} =
               SshKeys.add_key(account, %{"name" => type, "public_key" => public_key})

      assert key.fingerprint_sha256 =~ "SHA256:"
      assert key.key_type in SshKey.accepted_types()
    end
  end

  test "rejects garbage, private keys, and weak RSA", %{tmp_dir: tmp_dir} do
    account = account_fixture()

    assert {:error, changeset} =
             SshKeys.add_key(account, %{"name" => "junk", "public_key" => "not a key"})

    assert changeset.errors[:public_key]

    # A private key must never be accepted (or stored).
    private_path = Path.join(tmp_dir, "private")
    {_output, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-f", private_path, "-N", "", "-q"])

    assert {:error, changeset} =
             SshKeys.add_key(account, %{
               "name" => "private",
               "public_key" => File.read!(private_path)
             })

    assert changeset.errors[:public_key]

    weak_rsa = generate_key(tmp_dir, "rsa", extra: ["-b", "2048"])

    assert {:error, changeset} =
             SshKeys.add_key(account, %{"name" => "weak", "public_key" => weak_rsa})

    assert {"RSA keys need at least 3072 bits", _meta} = changeset.errors[:public_key]
  end

  test "a key registers to exactly one account", %{tmp_dir: tmp_dir} do
    public_key = generate_key(tmp_dir, "ed25519")
    first = account_fixture()
    second = account_fixture()

    assert {:ok, key} = SshKeys.add_key(first, %{"name" => "shared", "public_key" => public_key})

    assert {:error, changeset} =
             SshKeys.add_key(second, %{"name" => "stolen", "public_key" => public_key})

    assert changeset.errors[:fingerprint_sha256]

    {:ok, decoded, _type} = SshKey.decode_public_key(public_key)
    assert {:ok, account, resolved} = SshKeys.find_account_by_key(decoded)
    assert account.id == first.id
    assert resolved.id == key.id
  end

  test "enforces the per-account key cap", %{tmp_dir: tmp_dir} do
    account = account_fixture()

    for index <- 1..10 do
      public_key = generate_key(tmp_dir, "ed25519")

      assert {:ok, _key} =
               SshKeys.add_key(account, %{"name" => "k#{index}", "public_key" => public_key})
    end

    public_key = generate_key(tmp_dir, "ed25519")

    assert {:error, :key_limit} =
             SshKeys.add_key(account, %{"name" => "k11", "public_key" => public_key})
  end

  test "accounts remove only their own keys", %{tmp_dir: tmp_dir} do
    owner = account_fixture()
    other = account_fixture()
    public_key = generate_key(tmp_dir, "ed25519")

    {:ok, key} = SshKeys.add_key(owner, %{"name" => "mine", "public_key" => public_key})

    assert {:error, :not_found} = SshKeys.delete_key(other, key.id)
    assert {:ok, _deleted} = SshKeys.delete_key(owner, key.id)
    assert SshKeys.list_for_account(owner) == []
  end
end
