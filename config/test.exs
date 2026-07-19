import Config

config :tarakan, secure_cookies: false

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir, t_cost: 1, m_cost: 8

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tarakan, Tarakan.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tarakan_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :tarakan, Oban, testing: :manual

# Tests use the GitHub stub; enable REST object fallback with mirrors off.
config :tarakan, Tarakan.RepositoryMirror, enabled: false, rest_fallback: true

config :tarakan, Tarakan.HostedRepositories,
  root: "tmp/test_hosted#{System.get_env("MIX_TEST_PARTITION")}",
  max_push_bytes: 262_144_000,
  quota_bytes: 1_073_741_824

config :tarakan, TarakanWeb.GitHTTP,
  anonymous_rate_limit: {100_000, 60},
  account_rate_limit: {100_000, 60}

# Push bookkeeping runs inline so tests observe it deterministically.
config :tarakan, TarakanWeb.GitHTTP.Service, synchronous_post_receive: true

config :tarakan,
  github_client: Tarakan.GitHubStub,
  github_bulk_client: Tarakan.GitHubBulkStub,
  github_oauth_client: Tarakan.GitHub.OAuthStub,
  gitlab_oauth_client: Tarakan.GitLab.OAuthStub,
  request_completion_mode: :document_or_legacy_prose

# Epidemic tests: refresh rollups inline so list/get see data without Oban drain.
config :tarakan, :epidemics,
  read_from_rollup: true,
  refresh_async: true,
  sync_refresh: true

# LiveView tests assert immediate registry stat updates.
config :tarakan, :registry_stats_ttl_seconds, 0

config :tarakan, :github,
  client_id: "test-client-id",
  client_secret: "test-client-secret",
  api_token: nil

config :tarakan, Tarakan.RepositoryCode,
  global_upstream_limit: 100_000,
  repository_upstream_limit: 100_000,
  upstream_window_seconds: 60

config :tarakan, :gitlab,
  base_url: "https://gitlab.com",
  client_id: "test-gitlab-client-id",
  client_secret: "test-gitlab-client-secret"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tarakan, TarakanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vTG1EmduEPjiggdJIzKiBkK0Moh6gUUV8LlYu4qiKU/dsX4APCeA0kQPUH78NFDz",
  server: false

# In test we don't send emails
config :tarakan, Tarakan.Mailer, adapter: Swoosh.Adapters.Test

# Keep the limiter in the request path without coupling unrelated async tests
# to the same loopback-IP bucket. The limiter itself has focused low-limit tests.
config :tarakan, TarakanWeb.Plugs.ApiRateLimit,
  request_limit: 100_000,
  mutation_limit: 100_000

config :tarakan, TarakanWeb.BrowserRateLimit,
  login_ip: {100_000, 60},
  login_pair: {100_000, 300},
  magic_ip: {100_000, 3_600},
  magic_email: {100_000, 3_600},
  registration_ip: {100_000, 3_600}

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
