defmodule TarakanWeb.GitHTTP do
  @moduledoc """
  Git smart-HTTP endpoint for Tarakan-hosted repositories.

  Serves `https://…/:owner/:name.git` - `info/refs` advertisements plus the
  `git-upload-pack` (clone/fetch) and `git-receive-pack` (push) RPCs. Mounted
  in the endpoint ahead of `Plug.Parsers` so request bodies stream straight
  to the git subprocess instead of being buffered and size-capped as form
  input; every other request passes through to the router untouched.

  Authentication is HTTP Basic with a scoped API credential as the password;
  the username is ignored. Anonymous clients may clone listed repositories.
  Authorization always goes through `Tarakan.Policy` (`:clone_repository`,
  `:push_repository`). Failures follow the platform's anti-oracle rule: an
  unauthenticated client gets a 401 challenge so git prompts for
  credentials; an authenticated-but-unauthorized client gets the same 404 as
  a repository that does not exist.
  """

  @behaviour Plug

  import Plug.Conn

  alias Tarakan.Accounts
  alias Tarakan.HostedRepositories
  alias Tarakan.Policy
  alias Tarakan.RateLimiter
  alias Tarakan.Repositories.Repository
  alias TarakanWeb.GitHTTP.Service

  @services ~w(git-upload-pack git-receive-pack)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [owner, name_dot_git | rest]} = conn, _opts) do
    case repository_name(name_dot_git) do
      {:ok, name} -> dispatch(conn, owner, name, rest)
      :error -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp repository_name(segment) do
    case String.split(segment, ".git", parts: 2) do
      [name, ""] when name != "" -> {:ok, name}
      _other -> :error
    end
  end

  defp dispatch(%{method: "GET"} = conn, owner, name, ["info", "refs"]) do
    conn = fetch_query_params(conn)

    case conn.query_params["service"] do
      service when service in @services ->
        serve(conn, owner, name, service, :advertise)

      _missing ->
        # The dumb-HTTP protocol is not served; git falls back here only
        # when it cannot speak smart HTTP.
        halt_plain(conn, 400, "smart HTTP only")
    end
  end

  defp dispatch(%{method: "POST"} = conn, owner, name, [service])
       when service in @services do
    serve(conn, owner, name, service, :rpc)
  end

  defp dispatch(conn, _owner, _name, _rest) do
    halt_plain(conn, 404, "not found")
  end

  defp serve(conn, owner, name, service, mode) do
    with {:ok, conn, scope} <- authenticate(conn),
         :ok <- rate_limit(conn, scope),
         %Repository{} = repository <- HostedRepositories.resolve(owner, name),
         :ok <- authorize(scope, service, repository) do
      :telemetry.execute([:tarakan, :git, :http, :request], %{count: 1}, %{
        service: service,
        mode: mode,
        repository_id: repository.id,
        authenticated: scope != nil
      })

      case mode do
        :advertise -> Service.advertise_refs(conn, repository, service)
        :rpc -> Service.rpc(conn, repository, service, scope)
      end
    else
      {:unauthenticated, conn} ->
        challenge(conn)

      {:error, :rate_limited} ->
        halt_plain(conn, 429, "too many requests")

      # An unauthenticated client that fails authorization is challenged so
      # git retries with credentials; anything else is indistinguishable
      # from a missing repository.
      {:error, :unauthorized, nil} ->
        challenge(conn)

      {:error, :over_quota} ->
        halt_plain(conn, 413, "repository is over its storage quota")

      _denied ->
        halt_plain(conn, 404, "not found")
    end
  end

  defp authorize(scope, "git-upload-pack", repository) do
    case Policy.authorize(scope, :clone_repository, repository) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, :unauthorized, scope}
    end
  end

  # Authorization strictly precedes the quota check so an over-quota
  # response can never disclose an invisible repository.
  defp authorize(scope, "git-receive-pack", repository) do
    case Policy.authorize(scope, :push_repository, repository) do
      :ok -> ensure_not_over_quota(repository)
      {:error, :unauthorized} -> {:error, :unauthorized, scope}
    end
  end

  defp ensure_not_over_quota(repository) do
    if HostedRepositories.over_quota?(repository), do: {:error, :over_quota}, else: :ok
  end

  # Basic auth with the API credential as password. A present-but-invalid
  # credential is challenged rather than downgraded to anonymous.
  defp authenticate(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {_user, password} ->
        case Accounts.ApiCredentials.authenticate(password) do
          {:ok, account, credential} ->
            scope =
              Accounts.scope_for_account(account,
                token_id: credential.id,
                token_scopes: credential.scopes,
                token_repository_id: credential.repository_id,
                authentication_method: :api_credential
              )

            {:ok, conn, scope}

          :error ->
            {:unauthenticated, conn}
        end

      :error ->
        case get_req_header(conn, "authorization") do
          [] -> {:ok, conn, nil}
          _malformed -> {:unauthenticated, conn}
        end
    end
  end

  defp rate_limit(_conn, %{platform_role: role}) when role in ["admin", "moderator"], do: :ok

  defp rate_limit(_conn, %{account: %{platform_role: role}})
       when role in ["admin", "moderator"],
       do: :ok

  defp rate_limit(conn, scope) do
    {key, limit, window} = rate_limit_bucket(conn, scope)

    case RateLimiter.check(key, limit, window) do
      :ok -> :ok
      {:error, _reason, _retry_after} -> {:error, :rate_limited}
    end
  end

  defp rate_limit_bucket(conn, nil) do
    limits = config(:anonymous_rate_limit, {60, 60})
    {limit, window} = limits
    {{:git_http_ip, conn.remote_ip}, limit, window}
  end

  defp rate_limit_bucket(_conn, scope) do
    {limit, window} = config(:account_rate_limit, {240, 60})
    {{:git_http_account, scope.account_id}, limit, window}
  end

  defp challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="tarakan"))
    |> halt_plain(401, "authentication required")
  end

  defp halt_plain(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end

  defp config(key, default) do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
