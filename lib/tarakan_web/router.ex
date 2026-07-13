defmodule TarakanWeb.Router do
  use TarakanWeb, :router

  import TarakanWeb.AccountAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TarakanWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; base-uri 'self'; frame-ancestors 'self'; " <>
          "object-src 'none'; img-src 'self' data: https:; " <>
          "font-src 'self' data:; style-src 'self' 'unsafe-inline'; " <>
          "script-src 'self'; connect-src 'self' wss: ws:; form-action 'self'",
      "permissions-policy" => "camera=(), microphone=(), geolocation=()",
      "x-frame-options" => "SAMEORIGIN"
    }

    plug TarakanWeb.Plugs.CodeBrowserHeaders
    plug TarakanWeb.Plugs.CodeBrowserRateLimit
    plug :fetch_current_scope_for_account
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug TarakanWeb.Plugs.ApiRateLimit, mode: :ip
  end

  pipeline :api_authenticated do
    plug :fetch_api_account
    plug TarakanWeb.Plugs.ApiRateLimit, mode: :actor
  end

  pipeline :seo do
    plug :accepts, ["xml", "txt"]
  end

  scope "/", TarakanWeb do
    pipe_through :seo

    get "/robots.txt", SEOController, :robots
    get "/sitemap.xml", SEOController, :sitemap
  end

  scope "/", TarakanWeb do
    pipe_through :browser

    get "/auth/github", GitHubAuthController, :request
    get "/auth/github/callback", GitHubAuthController, :callback
    get "/auth/gitlab", GitLabAuthController, :request
    get "/auth/gitlab/callback", GitLabAuthController, :callback

    live_session :public, on_mount: [{TarakanWeb.AccountAuth, :mount_current_scope}] do
      live "/", RepositoryLive.Index, :index
      live "/explore", ExploreLive, :index
      live "/leaderboard", LeaderboardLive, :index
      live "/findings/:public_id", FindingLive.Show, :show
      live "/findings/:finding_ref/code", RepositoryCodeLive, :finding
      # Request (work queue) - /requests is preferred; /work kept for compatibility
      live "/requests/:id", ReviewTaskLive.Show, :show
      live "/work/:id", ReviewTaskLive.Show, :show
    end
  end

  scope "/api", TarakanWeb.API do
    pipe_through [:api]

    post "/client-auth/start", ClientAuthController, :start
    post "/client-auth/exchange", ClientAuthController, :exchange
  end

  scope "/api", TarakanWeb.API do
    pipe_through [:api, :api_authenticated]

    get "/repositories", RepositoryController, :index
    delete "/client-auth/session", ClientAuthController, :revoke

    # Global open Jobs queue, then per-id Request lifecycle.
    get "/requests", WorkController, :queue
    get "/jobs", WorkController, :queue
    get "/requests/:id", WorkController, :show
    post "/requests/:id/claim", WorkController, :claim
    post "/requests/:id/claim/renew", WorkController, :renew
    delete "/requests/:id/claim", WorkController, :release
    post "/requests/:id/complete", WorkController, :complete
    get "/work/:id", WorkController, :show
    post "/work/:id/claim", WorkController, :claim
    post "/work/:id/claim/renew", WorkController, :renew
    delete "/work/:id/claim", WorkController, :release
    post "/work/:id/complete", WorkController, :complete

    # Reports (mass) + Reviews + Scans (compat aliases - same controller)
    get "/:host/:owner/:name/reports", ScanController, :index
    get "/:host/:owner/:name/memory", ScanController, :memory
    post "/:host/:owner/:name/reports", ScanController, :create
    post "/:host/:owner/:name/findings/:public_id/check", ScanController, :finding_verdict
    post "/:host/:owner/:name/reports/:id/check", ScanController, :verdict
    post "/:host/:owner/:name/reports/:id/verdict", ScanController, :verdict
    get "/:host/:owner/:name/reviews", ScanController, :index
    post "/:host/:owner/:name/reviews", ScanController, :create
    post "/:host/:owner/:name/reviews/:id/verdict", ScanController, :verdict
    get "/:host/:owner/:name/scans", ScanController, :index
    post "/:host/:owner/:name/scans", ScanController, :create
    post "/:host/:owner/:name/scans/:id/verdict", ScanController, :verdict
    get "/:host/:owner/:name/requests", WorkController, :index
    get "/:host/:owner/:name/tasks", WorkController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tarakan, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TarakanWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TarakanWeb do
    pipe_through [:browser, :require_authenticated_account]

    live_session :require_authenticated_account,
      on_mount: [{TarakanWeb.AccountAuth, :require_authenticated}] do
      live "/accounts/settings", AccountLive.Settings, :edit
      live "/accounts/settings/confirm-email/:token", AccountLive.Settings, :confirm_email
      live "/client/authorize/:user_code", ClientAuthorizationLive, :show
      live "/admin", AdminLive.Index, :index
      live "/admin/accounts/:id", AdminLive.Show, :show
      live "/repositories/new", RepositoryLive.New, :new
      live "/moderation/report", ModerationReportLive.New, :new
      live "/moderation/cases/:id", ModerationCaseLive.Show, :show
      live "/moderation/queue", ModerationQueueLive.Index, :index
    end

    post "/accounts/update-password", AccountSessionController, :update_password
  end

  scope "/", TarakanWeb do
    pipe_through [:browser]

    live_session :current_account,
      on_mount: [{TarakanWeb.AccountAuth, :mount_current_scope}] do
      live "/accounts/register", AccountLive.Registration, :new
      live "/accounts/log-in", AccountLive.Login, :new
      live "/accounts/log-in/:token", AccountLive.Confirmation, :new
    end

    post "/accounts/log-in", AccountSessionController, :create
    delete "/accounts/log-out", AccountSessionController, :delete
  end

  ## Repository browsing
  #
  # Tarakan-hosted repositories live at GitHub-style bare paths
  # (/handle/name); remote repositories lead with their host's domain
  # (/github.com/owner/name, with legacy /github/... still resolving).
  #
  # Soundness: handles that would shadow a fixed route are reserved at
  # registration (Tarakan.Accounts.Account), handles can never contain a
  # dot, and host slugs are reserved handles - so a bare first segment is
  # classifiable in the mounts via Tarakan.Hosts.host_segment?/1. The bare
  # family is declared first so its literal segments win; when its first
  # segment is actually a host, the mount reinterprets the params. That
  # only happens for remote repositories literally named "code" or
  # "security" (their security tab is the one known-degraded corner).
  #
  # These wildcard routes must stay at the bottom of the router so they can
  # never shadow literal routes such as /accounts/log-in/:token.
  scope "/", TarakanWeb do
    pipe_through [:browser]

    live_session :repository_browser,
      on_mount: [{TarakanWeb.AccountAuth, :mount_current_scope}] do
      # A bare single segment is a contributor profile (GitHub-style
      # /handle). Handles that would shadow a fixed route are reserved at
      # registration, so this can never swallow /accounts, /work, etc.
      live "/:handle", AccountLive.Profile, :show

      live "/:owner/:name", RepositoryCodeLive, :entry
      live "/:owner/:name/security", RepositoryLive.Show, :show
      live "/:owner/:name/code", RepositoryCodeLive, :code_entry
      live "/:owner/:name/code/:commit_sha", RepositoryCodeLive, :show
      live "/:owner/:name/code/:commit_sha/*path", RepositoryCodeLive, :show

      live "/:host/:owner/:name", RepositoryCodeLive, :entry
      live "/:host/:owner/:name/security", RepositoryLive.Show, :show
      live "/:host/:owner/:name/code", RepositoryCodeLive, :entry
      live "/:host/:owner/:name/code/:commit_sha", RepositoryCodeLive, :show
      live "/:host/:owner/:name/code/:commit_sha/*path", RepositoryCodeLive, :show
    end
  end
end
