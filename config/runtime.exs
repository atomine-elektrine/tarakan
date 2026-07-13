import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tarakan start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tarakan, TarakanWeb.Endpoint, server: true
end

config :tarakan, TarakanWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

github_runtime_config =
  [
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
    api_token: System.get_env("GITHUB_TOKEN")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if github_runtime_config != [] do
  config :tarakan, :github, github_runtime_config
end

if mirror_dir = System.get_env("MIRROR_DIR") do
  config :tarakan, Tarakan.RepositoryMirror, root: mirror_dir
end

if hosted_dir = System.get_env("HOSTED_DIR") do
  config :tarakan, Tarakan.HostedRepositories, root: hosted_dir
end

git_ssh_runtime_config =
  [
    enabled: System.get_env("GIT_SSH_ENABLED") in ~w(true 1),
    port: System.get_env("GIT_SSH_PORT") && String.to_integer(System.get_env("GIT_SSH_PORT")),
    host_key_dir: System.get_env("GIT_SSH_HOST_KEY_DIR")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if System.get_env("GIT_SSH_ENABLED") do
  config :tarakan, Tarakan.GitSSH, git_ssh_runtime_config
end

gitlab_runtime_config =
  [
    base_url: System.get_env("GITLAB_URL"),
    client_id: System.get_env("GITLAB_CLIENT_ID"),
    client_secret: System.get_env("GITLAB_CLIENT_SECRET")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if gitlab_runtime_config != [] do
  config :tarakan, :gitlab, gitlab_runtime_config
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :tarakan, TarakanWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/tarakan_web/router\.ex$"E,
        ~r"lib/tarakan_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # verify_peer TLS to Postgres, on by default in prod (system CAs). Set
  # DATABASE_SSL=false for a co-located DB on a private network (docker compose).
  repo_ssl? = System.get_env("DATABASE_SSL", "true") in ~w(true 1)

  repo_opts = [
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6
  ]

  repo_opts =
    if repo_ssl? do
      Keyword.merge(repo_opts,
        ssl: true,
        ssl_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
      )
    else
      repo_opts
    end

  config :tarakan, Tarakan.Repo, repo_opts

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :tarakan, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Comma-separated IPs/CIDRs of reverse proxies allowed to set X-Forwarded-For.
  # Example: TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12,127.0.0.1
  trusted_proxies = Tarakan.TrustedProxies.parse(System.get_env("TRUSTED_PROXIES"))

  if trusted_proxies != [] do
    config :tarakan, :trusted_proxies, trusted_proxies
  end

  # Bind address. Defaults to dual-stack IPv6 (`::`), which also accepts IPv4.
  # Set PHX_IP=127.0.0.1 to bind loopback-only behind a same-host reverse proxy.
  # Any valid IPv4/IPv6 literal is accepted; a malformed value fails fast rather
  # than silently binding all interfaces.
  phx_ip = System.get_env("PHX_IP", "::")

  listen_ip =
    case :inet.parse_address(String.to_charlist(phx_ip)) do
      {:ok, ip} ->
        ip

      {:error, _reason} ->
        raise """
        environment variable PHX_IP is invalid: #{inspect(phx_ip)}
        Expected an IPv4 or IPv6 address, e.g. "::", "0.0.0.0", or "127.0.0.1".
        """
    end

  config :tarakan, TarakanWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      ip: listen_ip
    ],
    secret_key_base: secret_key_base

  elektrine_email_api_key =
    System.get_env("ELEKTRINE_EMAIL_API_KEY") ||
      raise "environment variable ELEKTRINE_EMAIL_API_KEY is missing"

  config :tarakan, Tarakan.Mailer,
    adapter: Tarakan.Mailer.ElektrineAdapter,
    api_key: elektrine_email_api_key,
    base_url: System.get_env("ELEKTRINE_EMAIL_API_URL", "https://elektrine.com")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tarakan, TarakanWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tarakan, TarakanWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
