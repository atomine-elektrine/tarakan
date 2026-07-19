# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tarakan, secure_cookies: true

config :tarakan, :scopes,
  account: [
    default: true,
    module: Tarakan.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:account, :id],
    schema_key: :account_id,
    schema_type: :id,
    schema_table: :accounts,
    test_data_fixture: Tarakan.AccountsFixtures,
    test_setup_helper: :register_and_log_in_account
  ]

config :tarakan,
  ecto_repos: [Tarakan.Repo],
  generators: [timestamp_type: :utc_datetime],
  github_client: Tarakan.GitHub.HTTPClient,
  github_bulk_client: Tarakan.GitHub.GraphQLClient,
  github_oauth_client: Tarakan.GitHub.OAuth.HTTPClient,
  gitlab_oauth_client: Tarakan.GitLab.OAuth.HTTPClient,
  # Finding-kind Request complete requires a Review Format document (Findings path).
  # Legacy prose remains for write_fix / verify_findings and for tests that opt into dual mode.
  request_completion_mode: :document_required

config :tarakan, :github,
  api_version: "2026-03-10",
  client_id: nil,
  client_secret: nil,
  api_token: nil

config :tarakan, Tarakan.RepositoryCode,
  global_upstream_limit: 240,
  repository_upstream_limit: 60,
  upstream_window_seconds: 60,
  identity_cache_ttl_ms: 3_000,
  identity_revalidation_ttl_ms: 86_400_000,
  head_cache_ttl_ms: 12_000,
  immutable_cache_ttl_ms: 86_400_000

config :tarakan, Tarakan.RepositoryMirror,
  enabled: true,
  # Production code browse uses git mirrors only (no GitHub REST for objects).
  rest_fallback: false,
  root: "priv/mirrors"

config :tarakan, Tarakan.HostedRepositories,
  root: "priv/hosted",
  max_push_bytes: 262_144_000,
  quota_bytes: 1_073_741_824

config :tarakan, Tarakan.GitSSH,
  enabled: false,
  port: 2222,
  host_key_dir: "priv/ssh"

# Cap concurrent git upload-pack/receive-pack processes (HTTP RPC + SSH).
config :tarakan, Tarakan.Git.Concurrency, max_concurrent: 32

config :tarakan, Oban,
  engine: Oban.Engines.Basic,
  repo: Tarakan.Repo,
  # epidemics: 1 keeps DB pool pressure low (compose POOL_SIZE default is 5).
  queues: [sync: 5, mirror: 3, epidemics: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Tarakan.Sync.RepositorySweep},
       {"30 3 * * *", Tarakan.Epidemics.Reconcile},
       {"0 4 * * 0", Tarakan.Sync.HostedRepositoryGC},
       {"0 * * * *", Tarakan.Epidemics.RecomputeWindows}
     ]}
  ]

# Epidemic rollups: async projection + dual-read. Tests set sync_refresh: true.
config :tarakan, :epidemics,
  read_from_rollup: true,
  refresh_async: true,
  sync_refresh: false

config :tarakan, :gitlab,
  base_url: "https://gitlab.com",
  client_id: nil,
  client_secret: nil

# Configure the endpoint
config :tarakan, TarakanWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TarakanWeb.ErrorHTML, json: TarakanWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tarakan.PubSub,
  live_view: [signing_salt: "Ht50NGTc"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tarakan, Tarakan.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tarakan: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  tarakan: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix,
  json_library: Jason,
  filter_parameters: [
    "authorization",
    "code",
    "credential",
    "description",
    "document",
    "evidence",
    "findings",
    "findings_json",
    "notes",
    "password",
    "reason",
    "secret",
    "summary",
    "token"
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
