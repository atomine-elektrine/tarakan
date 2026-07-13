defmodule Tarakan.GitSSHTest do
  @moduledoc """
  End-to-end SSH tests driven by real `git` + OpenSSH clients against the
  OTP `:ssh` daemon.
  """

  use Tarakan.DataCase, async: false

  import Tarakan.AccountsFixtures

  alias Tarakan.Accounts
  alias Tarakan.Accounts.SshKeys
  alias Tarakan.HostedRepositories

  @moduletag :git_client
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn ->
      File.rm_rf(Application.fetch_env!(:tarakan, Tarakan.HostedRepositories)[:root])
    end)

    Tarakan.RepositoryCode.Cache.clear()

    start_supervised!(
      {Tarakan.GitSSH.Server, enabled: true, port: 0, host_key_dir: "tmp/test_ssh_host"}
    )

    {:ok, port} = Tarakan.GitSSH.Server.bound_port()

    account = account_fixture()
    scope = Accounts.scope_for_account(account)
    {:ok, repository} = HostedRepositories.create(scope, %{"name" => "sshhosted"})

    key_path = Path.join(tmp_dir, "id_ed25519")

    {_output, 0} =
      System.cmd("ssh-keygen", ["-t", "ed25519", "-f", key_path, "-N", "", "-q"],
        stderr_to_stdout: true
      )

    {:ok, ssh_key} =
      SshKeys.add_key(account, %{
        "name" => "test key",
        "public_key" => File.read!(key_path <> ".pub")
      })

    %{
      port: port,
      account: account,
      repository: repository,
      key_path: key_path,
      ssh_key: ssh_key
    }
  end

  defp git_env(key_path) do
    # tmp_dir contains the test name (spaces, quotes) - the -i path must be
    # quoted or git misparses GIT_SSH_COMMAND.
    ssh_command =
      ~s(ssh -i "#{key_path}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ) <>
        "-o IdentitiesOnly=yes -o IdentityAgent=none"

    [
      {"GIT_SSH_COMMAND", ssh_command},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]
  end

  defp git(key_path, args) do
    System.cmd("git", args, stderr_to_stdout: true, env: git_env(key_path))
  end

  defp ssh_url(%{port: port, account: account}, name),
    do: "ssh://git@127.0.0.1:#{port}/#{account.handle}/#{name}.git"

  defp seed_local_repository(tmp_dir, key_path) do
    work = Path.join(tmp_dir, "seed")
    File.mkdir_p!(work)
    {_out, 0} = git(key_path, ["init", "--quiet", "-b", "main", work])
    File.write!(Path.join(work, "README.md"), "# Over SSH\n")
    {_out, 0} = git(key_path, ["-C", work, "add", "."])
    {_out, 0} = git(key_path, ["-C", work, "commit", "--quiet", "-m", "seed"])
    work
  end

  test "push, clone, and fetch round-trip over SSH", context do
    %{tmp_dir: tmp_dir, key_path: key_path, repository: repository, ssh_key: ssh_key} = context
    work = seed_local_repository(tmp_dir, key_path)
    url = ssh_url(context, "sshhosted")

    {output, status} = git(key_path, ["-C", work, "push", "--quiet", url, "main"])
    assert status == 0, output

    repository = Repo.reload!(repository)
    assert repository.default_branch == "main"
    assert %DateTime{} = repository.pushed_at

    assert %DateTime{} = Repo.reload!(ssh_key).last_used_at

    dest = Path.join(tmp_dir, "clone")
    {output, status} = git(key_path, ["clone", "--quiet", url, dest])
    assert status == 0, output
    assert File.read!(Path.join(dest, "README.md")) == "# Over SSH\n"

    # A second push then a pull exercises multi-round negotiation, which is
    # why SSH transport must not run in stateless-rpc mode.
    File.write!(Path.join(work, "second.txt"), "more\n")
    {_out, 0} = git(key_path, ["-C", work, "add", "."])
    {_out, 0} = git(key_path, ["-C", work, "commit", "--quiet", "-m", "second"])
    {_out, 0} = git(key_path, ["-C", work, "push", "--quiet", url, "main"])

    {output, status} = git(key_path, ["-C", dest, "pull", "--quiet", "origin", "main"])
    assert status == 0, output
    assert File.read!(Path.join(dest, "second.txt")) == "more\n"
  end

  test "an unregistered key cannot authenticate", context do
    %{tmp_dir: tmp_dir} = context

    rogue_key = Path.join(tmp_dir, "rogue")

    {_output, 0} =
      System.cmd("ssh-keygen", ["-t", "ed25519", "-f", rogue_key, "-N", "", "-q"],
        stderr_to_stdout: true
      )

    dest = Path.join(tmp_dir, "clone")
    {output, status} = git(rogue_key, ["clone", "--quiet", ssh_url(context, "sshhosted"), dest])
    assert status != 0
    assert output =~ "Permission denied" or output =~ "denied"
  end

  test "a registered key without membership can read but not push a hosted repository",
       context do
    %{tmp_dir: tmp_dir, key_path: key_path} = context

    other = account_fixture()
    other_key = Path.join(tmp_dir, "other")

    {_output, 0} =
      System.cmd("ssh-keygen", ["-t", "ed25519", "-f", other_key, "-N", "", "-q"],
        stderr_to_stdout: true
      )

    {:ok, _key} =
      SshKeys.add_key(other, %{
        "name" => "other key",
        "public_key" => File.read!(other_key <> ".pub")
      })

    work = seed_local_repository(tmp_dir, key_path)
    url = ssh_url(context, "sshhosted")

    {_output, 0} = git(key_path, ["-C", work, "push", "--quiet", url, "main"])

    dest = Path.join(tmp_dir, "clone")
    {_output, status} = git(other_key, ["clone", "--quiet", url, dest])
    assert status == 0

    {output, status} = git(other_key, ["-C", work, "push", "--quiet", url, "main"])
    assert status != 0

    assert output =~ "repository not found" or output =~ "denied" or
             output =~ "not authorized"
  end

  test "a key cannot log in as somebody else's handle", context do
    %{tmp_dir: tmp_dir, key_path: key_path, port: port} = context

    other = account_fixture()

    url = "ssh://#{other.handle}@127.0.0.1:#{port}/#{other.handle}/anything.git"
    dest = Path.join(tmp_dir, "clone")

    {output, status} = git(key_path, ["clone", "--quiet", url, dest])
    assert status != 0
    assert output =~ "Permission denied" or output =~ "denied", "unexpected output: #{output}"
  end

  test "arbitrary exec commands are refused", context do
    %{key_path: key_path, port: port} = context

    {output, status} =
      System.cmd(
        "ssh",
        [
          "-i",
          key_path,
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null",
          "-o",
          "IdentitiesOnly=yes",
          "-p",
          "#{port}",
          "git@127.0.0.1",
          "ls -la /"
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "only git-upload-pack and git-receive-pack are supported"
  end

  test "shell sessions are refused", context do
    %{key_path: key_path, port: port} = context

    {_output, status} =
      System.cmd(
        "ssh",
        [
          "-i",
          key_path,
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null",
          "-o",
          "IdentitiesOnly=yes",
          "-T",
          "-p",
          "#{port}",
          "git@127.0.0.1"
        ],
        stderr_to_stdout: true
      )

    assert status != 0
  end

  test "traversal-shaped repository paths are rejected", context do
    %{tmp_dir: tmp_dir, key_path: key_path, port: port} = context

    for path <- ["../../etc/passwd", "a/../../b.git", "'; ls '"] do
      url = "ssh://git@127.0.0.1:#{port}/#{path}"
      dest = Path.join(tmp_dir, "clone-#{System.unique_integer([:positive])}")
      {output, status} = git(key_path, ["clone", "--quiet", url, dest])
      assert status != 0

      assert output =~ "only git-upload-pack" or output =~ "repository not found",
             "unexpected output for #{path}: #{output}"
    end
  end
end
