defmodule TarakanWeb.GitHTTPTest do
  @moduledoc """
  End-to-end smart-HTTP tests driven by a real git client against a real
  Bandit listener serving the full endpoint.
  """

  use Tarakan.DataCase, async: false

  import Tarakan.AccountsFixtures

  alias Tarakan.Accounts
  alias Tarakan.HostedRepositories

  @moduletag :git_client

  setup do
    on_exit(fn ->
      File.rm_rf(Application.fetch_env!(:tarakan, Tarakan.HostedRepositories)[:root])
    end)

    Tarakan.RepositoryCode.Cache.clear()

    port = free_port()

    start_supervised!(
      {Bandit, plug: TarakanWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: port}
    )

    account = account_fixture()
    scope = Accounts.scope_for_account(account)
    {:ok, repository} = HostedRepositories.create(scope, %{"name" => "hosted"})

    {:ok, token, _credential} =
      Accounts.ApiCredentials.create(account, %{
        "name" => "git",
        "scopes" => ["repo:read", "repo:write"]
      })

    %{
      port: port,
      account: account,
      repository: repository,
      token: token,
      base_url: "http://127.0.0.1:#{port}"
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp git_env do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]
  end

  defp git(args, opts \\ []) do
    System.cmd("git", args, [stderr_to_stdout: true, env: git_env()] ++ opts)
  end

  defp clone_url(%{base_url: base_url, account: account}, name),
    do: "#{base_url}/#{account.handle}/#{name}.git"

  defp authed_url(%{token: token} = context, name) do
    %URI{URI.parse(clone_url(context, name)) | userinfo: "git:#{token}"} |> URI.to_string()
  end

  defp seed_local_repository(tmp_dir) do
    work = Path.join(tmp_dir, "seed")
    File.mkdir_p!(work)
    {_out, 0} = git(["init", "--quiet", "-b", "main", work])
    File.write!(Path.join(work, "README.md"), "# Pushed\n")
    {_out, 0} = git(["-C", work, "add", "."])
    {_out, 0} = git(["-C", work, "commit", "--quiet", "-m", "seed"])
    work
  end

  defp list_repository(repository) do
    repository
    |> Ecto.Changeset.change(listing_status: "listed")
    |> Repo.update!()
  end

  describe "push over HTTP" do
    @tag :tmp_dir
    test "steward pushes with a repo:write credential", context do
      %{repository: repository, tmp_dir: tmp_dir} = context
      work = seed_local_repository(tmp_dir)

      {output, status} =
        git(["-C", work, "push", "--quiet", authed_url(context, "hosted"), "main"])

      assert status == 0, output

      repository = Repo.reload!(repository)
      assert repository.default_branch == "main"
      assert %DateTime{} = repository.pushed_at
      assert repository.disk_size_bytes > 0

      assert %{action: "repository_pushed"} =
               Repo.get_by(Tarakan.Audit.Event, action: "repository_pushed")
    end

    @tag :tmp_dir
    test "push is denied without credentials, with read-only scope, and for non-stewards",
         context do
      %{tmp_dir: tmp_dir, account: account} = context
      work = seed_local_repository(tmp_dir)

      # Anonymous: the server answers 401 so git asks for credentials, and
      # with prompts disabled the push dies without touching the repository.
      {:ok, {{_http, 401, _reason}, _headers, _body}} =
        :httpc.request(
          :get,
          {~c"#{clone_url(context, "hosted")}/info/refs?service=git-receive-pack", []},
          [autoredirect: false],
          []
        )

      {output, status} =
        git(["-C", work, "push", "--quiet", clone_url(context, "hosted"), "main"])

      assert status != 0
      assert output =~ "Authentication" or output =~ "401" or output =~ "prompts disabled"

      # Authenticated but read-only scope.
      {:ok, read_token, _credential} =
        Accounts.ApiCredentials.create(account, %{
          "name" => "read-only",
          "scopes" => ["repo:read"]
        })

      read_url =
        %URI{URI.parse(clone_url(context, "hosted")) | userinfo: "git:#{read_token}"}
        |> URI.to_string()

      {output, status} = git(["-C", work, "push", "--quiet", read_url, "main"])
      assert status != 0
      assert output =~ "404" or output =~ "not found"

      # A different account with a valid repo:write credential but no
      # steward membership.
      other = account_fixture()

      {:ok, other_token, _credential} =
        Accounts.ApiCredentials.create(other, %{
          "name" => "other",
          "scopes" => ["repo:write"]
        })

      other_url =
        %URI{URI.parse(clone_url(context, "hosted")) | userinfo: "git:#{other_token}"}
        |> URI.to_string()

      {output, status} = git(["-C", work, "push", "--quiet", other_url, "main"])
      assert status != 0
      assert output =~ "404" or output =~ "not found"

      assert Repo.reload!(context.repository).pushed_at == nil
    end
  end

  describe "clone over HTTP" do
    @tag :tmp_dir
    test "anonymous clone of a listed repository round-trips content", context do
      %{repository: repository, tmp_dir: tmp_dir} = context
      work = seed_local_repository(tmp_dir)

      {_output, 0} =
        git(["-C", work, "push", "--quiet", authed_url(context, "hosted"), "main"])

      list_repository(repository)

      dest = Path.join(tmp_dir, "clone")
      {output, status} = git(["clone", "--quiet", clone_url(context, "hosted"), dest])
      assert status == 0, output
      assert File.read!(Path.join(dest, "README.md")) == "# Pushed\n"
    end

    @tag :tmp_dir
    test "anonymous clone succeeds at creation and is refused after quarantine", context do
      %{repository: repository, tmp_dir: tmp_dir} = context
      work = seed_local_repository(tmp_dir)

      {_output, 0} =
        git(["-C", work, "push", "--quiet", authed_url(context, "hosted"), "main"])

      # Hosted repositories are listed at creation, so an anonymous clone
      # works without any moderation step.
      dest = Path.join(tmp_dir, "clone")
      {output, status} = git(["clone", "--quiet", clone_url(context, "hosted"), dest])
      assert status == 0, output
      assert File.read!(Path.join(dest, "README.md")) == "# Pushed\n"

      # A moderator quarantine is the only thing that hides the repository.
      repository
      |> Tarakan.Repositories.Repository.listing_changeset(%{listing_status: "quarantined"})
      |> Repo.update!()

      {:ok, {{_http, 401, _reason}, _headers, _body}} =
        :httpc.request(
          :get,
          {~c"#{clone_url(context, "hosted")}/info/refs?service=git-upload-pack", []},
          [autoredirect: false],
          []
        )

      quarantined_dest = Path.join(tmp_dir, "clone-quarantined")

      {output, status} =
        git(["clone", "--quiet", clone_url(context, "hosted"), quarantined_dest])

      assert status != 0
      assert output =~ "Authentication" or output =~ "401" or output =~ "prompts disabled"
    end

    @tag :tmp_dir
    test "the owner clones a repository with a credential", context do
      %{tmp_dir: tmp_dir} = context
      work = seed_local_repository(tmp_dir)

      {_output, 0} =
        git(["-C", work, "push", "--quiet", authed_url(context, "hosted"), "main"])

      dest = Path.join(tmp_dir, "clone")
      {output, status} = git(["clone", "--quiet", authed_url(context, "hosted"), dest])
      assert status == 0, output
      assert File.read!(Path.join(dest, "README.md")) == "# Pushed\n"
    end

    @tag :tmp_dir
    test "fetch after a new push exercises negotiation", context do
      %{repository: repository, tmp_dir: tmp_dir} = context
      work = seed_local_repository(tmp_dir)

      {_output, 0} =
        git(["-C", work, "push", "--quiet", authed_url(context, "hosted"), "main"])

      list_repository(repository)

      dest = Path.join(tmp_dir, "clone")
      {_output, 0} = git(["clone", "--quiet", clone_url(context, "hosted"), dest])

      File.write!(Path.join(work, "second.txt"), "more\n")
      {_out, 0} = git(["-C", work, "add", "."])
      {_out, 0} = git(["-C", work, "commit", "--quiet", "-m", "second"])

      {_output, 0} =
        git(["-C", work, "push", "--quiet", authed_url(context, "hosted"), "main"])

      {output, status} = git(["-C", dest, "pull", "--quiet", "origin", "main"])
      assert status == 0, output
      assert File.read!(Path.join(dest, "second.txt")) == "more\n"
    end

    test "unknown repositories 404 without an existence oracle", context do
      %{base_url: base_url} = context

      {:ok, {{_http, 404, _reason}, _headers, _body}} =
        :httpc.request(
          :get,
          {~c"#{base_url}/nobody/nothing.git/info/refs?service=git-upload-pack", []},
          [],
          []
        )
    end

    test "non-git routes still reach Phoenix", context do
      {:ok, {{_http, 200, _reason}, _headers, body}} =
        :httpc.request(:get, {~c"#{context.base_url}/", []}, [], [])

      assert to_string(body) =~ "<html"
    end
  end

  describe "protocol details" do
    @tag :tmp_dir
    test "info/refs advertisement uses the smart content type", context do
      %{repository: repository} = context
      list_repository(repository)

      url =
        ~c"#{clone_url(context, "hosted")}/info/refs?service=git-upload-pack"

      {:ok, {{_http, 200, _reason}, headers, body}} = :httpc.request(:get, {url, []}, [], [])

      content_type =
        headers
        |> Enum.find_value(fn
          {~c"content-type", value} -> to_string(value)
          _other -> nil
        end)

      assert content_type == "application/x-git-upload-pack-advertisement"
      assert to_string(body) =~ "# service=git-upload-pack"
      assert String.starts_with?(to_string(body), "001e# service=git-upload-pack\n0000")
    end

    @tag :tmp_dir
    test "a truncated RPC body cannot wedge the subprocess", context do
      %{repository: repository, tmp_dir: tmp_dir} = context
      work = seed_local_repository(tmp_dir)

      {_output, 0} =
        git(["-C", work, "push", "--quiet", authed_url(context, "hosted"), "main"])

      list_repository(repository)

      # A syntactically incomplete upload-pack request: git waits for the
      # rest of the negotiation, and only the wall-clock deadline ends it.
      original = Application.get_env(:tarakan, TarakanWeb.GitHTTP.Service, [])

      Application.put_env(
        :tarakan,
        TarakanWeb.GitHTTP.Service,
        Keyword.put(original, :upload_pack_timeout_ms, 300)
      )

      on_exit(fn -> Application.put_env(:tarakan, TarakanWeb.GitHTTP.Service, original) end)

      truncated = "00a4want "

      {time_us, {:ok, {{_http, 200, _reason}, _headers, _body}}} =
        :timer.tc(fn ->
          :httpc.request(
            :post,
            {~c"#{clone_url(context, "hosted")}/git-upload-pack",
             [{~c"content-type", ~c"application/x-git-upload-pack-request"}],
             ~c"application/x-git-upload-pack-request", truncated},
            [timeout: 5_000],
            []
          )
        end)

      # Bounded by the configured deadline, not the httpc timeout.
      assert div(time_us, 1000) < 4_000
    end

    test "dumb-protocol requests are refused", context do
      %{repository: repository} = context
      list_repository(repository)

      {:ok, {{_http, 400, _reason}, _headers, _body}} =
        :httpc.request(
          :get,
          {~c"#{clone_url(context, "hosted")}/info/refs", []},
          [],
          []
        )
    end
  end
end
